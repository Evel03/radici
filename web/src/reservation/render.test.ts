import { describe, expect, it } from "vitest";
import type { ClientLinkView } from "../../../supabase/functions/_shared/client_link.ts";
import type { Lang } from "../i18n/core.ts";
import { find, findAll, textOf, toHtml, type VNode } from "../lib/vdom.ts";
import { i18nFor } from "../request/fixtures.ts";
import type { PageState, WeekUi } from "./controller.ts";
import { PHOTO, content, menu, view, week } from "./fixtures.ts";
import { DISH_PHOTO_SIZE, changesCountText, focusId, messageText, reservationTree } from "./render.ts";

const NBSP = String.fromCharCode(0xa0);
const EMPTY_UI: WeekUi = { formOpen: false, draft: "", busy: null, error: null, textError: false, notice: null };

function render(state: PageState, lang: Lang = "it", ui: Partial<Record<number, Partial<WeekUi>>> = {}, failedPhotos?: ReadonlySet<string>): VNode {
  return reservationTree({
    state,
    i18n: i18nFor(lang),
    ui: (n) => ({ ...EMPTY_UI, ...ui[n] }),
    ...(failedPhotos ? { failedPhotos } : {}),
  });
}

const ready = (value: ClientLinkView = view()): PageState => ({ kind: "ready", view: value });
const byId = (tree: VNode, id: string): VNode | null => find(tree, (node) => node.attrs["id"] === id);
const byClass = (tree: VNode, cls: string): VNode[] => findAll(tree, (node) => (node.attrs["class"] ?? "").split(" ").includes(cls));
const texts = (tree: VNode, cls: string): string[] => byClass(tree, cls).map(textOf);

describe("la reserva, en italiano", () => {
  const tree = render(ready());

  it("saludo con el nombre de pila y la presentación con la cocinera", () => {
    expect(texts(tree, "reservation__greeting")).toEqual(["Ciao Anna!"]);
    expect(texts(tree, "reservation__lead")[0]).toContain("con Evelyn");
  });

  it("cada semana: «Settimana k di N», la fecha y la hora de llegada", () => {
    expect(texts(tree, "week__title")).toEqual(["Settimana 1 di 2", "Settimana 2 di 2"]);
    expect(texts(tree, "week__when")).toEqual(["lunedì 1 marzo 2027 · arrivo alle 10:00", "lunedì 8 marzo 2027 · arrivo alle 10:00"]);
  });

  it("una semana sin menú dice que lo manda Evelyn", () => {
    const second = byId(tree, "week-2");
    expect(second && textOf(second)).toContain("Il menù di questa settimana te lo manda Evelyn nei prossimi giorni.");
    expect(second && byClass(second, "week__status")).toEqual([]);
  });

  it("el estado del menú: por confirmar, con la fecha del envío (en Roma)", () => {
    const status = byId(tree, "week-1-status");
    expect(status?.attrs["tabindex"]).toBe("-1");
    expect(status && textOf(status)).toBe("Da confermare Evelyn ti ha mandato questo menù il 25 febbraio 2027.");
  });

  it("los platos: foto, nombre, descripción, porciones, dieta y alérgenos con su nombre", () => {
    const dishes = byClass(tree, "dish");
    expect(dishes).toHaveLength(2);
    const [lasagne, minestrone] = dishes;
    expect(lasagne?.attrs["class"]).toBe("dish dish--photo");
    const img = lasagne && find(lasagne, (node) => node.tag === "img");
    expect(img?.attrs).toEqual({
      class: "dish__photo",
      src: PHOTO.thumb,
      alt: "",
      width: String(DISH_PHOTO_SIZE),
      height: String(DISH_PHOTO_SIZE),
      loading: "lazy",
      decoding: "async",
    });
    expect(lasagne && texts(lasagne, "dish__name")).toEqual(["Lasagne al ragù"]);
    expect(lasagne && texts(lasagne, "dish__desc")).toEqual(["Ragù di manzo e besciamella."]);
    expect(lasagne && texts(lasagne, "dish__meta")).toEqual(["6 porzioni"]);
    expect(lasagne && texts(lasagne, "allergens__item")).toEqual(["glutine", "uova", "latte e derivati"]);
    const list = lasagne && find(lasagne, (node) => node.tag === "ul");
    const label = list && byId(lasagne, list.attrs["aria-labelledby"] ?? "");
    expect(label && textOf(label)).toBe("Allergeni:");

    expect(minestrone?.attrs["class"]).toBe("dish");
    expect(minestrone && find(minestrone, (node) => node.tag === "img")).toBeNull();
    expect(minestrone && texts(minestrone, "dish__meta")).toEqual([`1 porzione${NBSP}· Vegano`]);
    expect(minestrone && texts(minestrone, "dish__allergens")).toEqual(["Nessuno dei 14 allergeni principali"]);
    expect(minestrone && byClass(minestrone, "dish__desc")).toEqual([]);
  });

  it("la lista de compras por sección, con las cantidades lindas, y aparte lo que hay que tener en casa", () => {
    expect(texts(tree, "shopping__section")).toEqual(["Frutta e verdura", "Latticini e uova", "Da avere in casa"]);
    const rows = byClass(tree, "shopping__item").map((row) => [texts(row, "shopping__name")[0], texts(row, "shopping__qty")[0] ?? null]);
    expect(rows).toEqual([
      ["Pomodori", `1,25${NBSP}kg`],
      ["Zucchine", `250${NBSP}g`],
      ["Latte", `1,5${NBSP}l`],
      ["Uova", "3 pezzi"],
      ["Sale", null],
      ["Olio", null],
    ]);
    expect(texts(tree, "menu__intro")).toEqual(["La spesa la fai tu: ecco cosa serve per questa settimana."]);
  });

  it("la nota de Evelyn, con sus saltos de línea, como texto", () => {
    const note = byClass(tree, "menu__note")[0];
    expect(note?.children).toEqual(["Ciao Anna!\nArrivo alle 10."]);
    expect(texts(tree, "menu__title")).toContain("Nota di Evelyn");
  });

  it("por confirmar: «Confermo il menù» y «Chiedo dei cambi», con la semana", () => {
    const confirm = byId(tree, "week-1-confirm");
    expect(confirm?.attrs).toMatchObject({ type: "button", "data-action": "confirm", "data-week": "1" });
    expect(confirm && textOf(confirm)).toBe("Confermo il menù");
    expect(confirm?.attrs["aria-disabled"]).toBeUndefined();
    const changes = byId(tree, "week-1-changes");
    expect(changes?.attrs).toMatchObject({ "data-action": "open-changes", "data-week": "1" });
    expect(changes && textOf(changes)).toBe("Chiedo dei cambi");
  });

  it("nada de precios, pagos ni direcciones", () => {
    expect(toHtml(tree)).not.toMatch(/€|EUR|prezzo|pagament|indirizzo/i);
  });
});

describe("en español y en inglés", () => {
  it("los textos, las fechas y las cantidades en el idioma de la página", () => {
    const es = render(ready(), "es");
    expect(texts(es, "reservation__greeting")).toEqual(["¡Hola, Anna!"]);
    expect(texts(es, "week__title")).toEqual(["Semana 1 de 2", "Semana 2 de 2"]);
    expect(texts(es, "week__when")[0]).toBe("lunes, 1 de marzo de 2027 · llegada a las 10:00");
    expect(textOf(byId(es, "week-1-status") ?? "")).toBe("Por confirmar Evelyn te mandó este menú el 25 de febrero de 2027.");
    expect(texts(es, "allergens__item")).toEqual(["gluten", "huevos", "leche y lácteos"]);
    expect(texts(es, "shopping__qty")).toEqual([`1,25${NBSP}kg`, `250${NBSP}g`, `1,5${NBSP}l`, "3 unidades"]);
    expect(texts(es, "shopping__section")).toEqual(["Fruta y verdura", "Lácteos y huevos", "Para tener en casa"]);

    const en = render(ready(), "en");
    expect(texts(en, "reservation__greeting")).toEqual(["Hi Anna!"]);
    expect(texts(en, "week__title")[0]).toBe("Week 1 of 2");
    expect(texts(en, "week__when")[0]).toBe("Monday 1 March 2027 · arriving at 10:00");
    expect(texts(en, "shopping__qty")).toEqual([`1.25${NBSP}kg`, `250${NBSP}g`, `1.5${NBSP}l`, "3 pieces"]);
    expect(textOf(byId(en, "week-1-confirm") ?? "")).toBe("I confirm the menu");
  });

  it("los textos del envío conservan su idioma (lang) si la página está en otro", () => {
    const es = render(ready(), "es");
    for (const cls of ["dish__name", "dish__desc", "shopping__name", "menu__note"]) {
      for (const node of byClass(es, cls)) expect(node.attrs["lang"], cls).toBe("it");
    }
    // En el mismo idioma, sin lang de más.
    const it = render(ready(), "it");
    expect(byClass(it, "dish__name")[0]?.attrs["lang"]).toBeUndefined();
  });
});

describe("todo lo que llega de afuera va como texto", () => {
  it("un plato, un renglón y una nota con HTML quedan escapados", () => {
    const evil = '<img src=x onerror="alert(1)">';
    const tree = render(
      ready(
        view({
          clientFirstName: "Anna",
          chefName: "<b>Eve</b>",
          weeks: [
            week({
              menu: menu({
                content: content({
                  dishes: [{ name: evil, description: `${evil} desc`, allergens: [], diet: null, portions: 2, photo: null }],
                  items: [{ name: `<script>alert(1)</script>`, section: "other", quantity: 2, unit: "pcs" }],
                  note: `</p><script>alert(1)</script>`,
                }),
              }),
            }),
          ],
        }),
      ),
    );
    const html = toHtml(tree);
    expect(html).not.toContain("<img src=x");
    expect(html).not.toContain("<script>");
    expect(html).not.toContain("<b>Eve</b>");
    expect(html).toContain("&lt;img src=x onerror=&quot;alert(1)&quot;&gt;");
    expect(html).toContain("&lt;script&gt;alert(1)&lt;/script&gt;");
    expect(html).toContain("&lt;b&gt;Eve&lt;/b&gt;");
    expect(findAll(tree, (node) => Object.keys(node.attrs).some((name) => name.startsWith("on")))).toEqual([]);
    expect(findAll(tree, (node) => node.tag === "script")).toEqual([]);
  });
});

describe("estados de una semana", () => {
  it("confirmado: sin botones, con la fecha de la confirmación", () => {
    const tree = render(ready(view({ weeks: [week({ menu: menu({ state: "confirmed", confirmedAt: "2027-02-26T10:00:00+00:00" }) })] })));
    expect(textOf(byId(tree, "week-1-status") ?? "")).toBe("Confermato L'hai confermato il 26 febbraio 2027.");
    expect(byId(tree, "week-1-confirm")).toBeNull();
    expect(byId(tree, "week-1-changes")).toBeNull();
    expect(byClass(tree, "week__status")[0]?.attrs["class"]).toBe("week__status week__status--confirmed");
  });

  it("con cambios pedidos: sin botones, dice que Evelyn lo manda de nuevo", () => {
    const tree = render(ready(view({ weeks: [week({ menu: menu({ state: "changesRequested", changesRequestedAt: "2027-02-26T10:00:00+00:00" }) })] })));
    expect(textOf(byId(tree, "week-1-status") ?? "")).toBe("Cambi chiesti Hai chiesto dei cambi il 26 febbraio 2027: Evelyn ti manderà il menù di nuovo.");
    expect(byId(tree, "week-1-confirm")).toBeNull();
    expect(byId(tree, "week-1-form")).toBeNull();
  });

  it("ya cocinada: se ve el menú, sin botones", () => {
    const tree = render(ready(view({ weeks: [week({ done: true })] })));
    expect(texts(tree, "week__done")).toEqual(["Evelyn ha già cucinato questa settimana."]);
    expect(byClass(tree, "dish")).toHaveLength(2);
    expect(byId(tree, "week-1-confirm")).toBeNull();
  });

  it("un envío que no se puede mostrar: lo dice y no deja contestar", () => {
    const tree = render(ready(view({ weeks: [week({ menu: menu({ content: null }) })] })));
    expect(textOf(tree)).toContain("Non riusciamo a mostrare qui questo menù. Scrivi a Evelyn: te lo rimanda.");
    expect(byId(tree, "week-1-confirm")).toBeNull();
    expect(byClass(tree, "dish")).toEqual([]);
  });

  it("el aviso de la última respuesta va en el estado (que recibe el foco)", () => {
    const tree = render(ready(view({ weeks: [week({ menu: menu({ state: "confirmed", confirmedAt: "2027-02-26T10:00:00+00:00" }) })] })), "it", {
      1: { notice: { key: "reservation.notices.confirmed" } },
    });
    const status = byId(tree, "week-1-status");
    expect(status && texts(status, "week__notice")).toEqual(["Grazie! Abbiamo avvisato Evelyn."]);
  });

  it("con una respuesta en camino: los botones quedan aria-disabled (conservan el foco) y dicen «Un momento…»", () => {
    const tree = render(ready(), "it", { 1: { busy: "confirm" } });
    expect(byId(tree, "week-1-confirm")?.attrs["aria-disabled"]).toBe("true");
    expect(byId(tree, "week-1-confirm")?.attrs["disabled"]).toBeUndefined();
    expect(textOf(byId(tree, "week-1-confirm") ?? "")).toBe("Un momento…");
    expect(byId(tree, "week-1-changes")?.attrs["aria-disabled"]).toBe("true");
  });

  it("un error de la última respuesta, junto a los botones", () => {
    const tree = render(ready(), "it", { 1: { error: { key: "reservation.errors.network" } } });
    expect(textOf(byId(tree, "week-1-error") ?? "")).toBe("Non riusciamo a collegarci. Controlla la connessione e riprova.");
  });

  it("el formulario de cambios: etiqueta, aviso de no escribir datos de salud, tope, contador y botones", () => {
    const tree = render(ready(), "it", { 1: { formOpen: true, draft: "Senza cipolla" } });
    expect(byId(tree, "week-1-confirm")).toBeNull();
    const form = byId(tree, "week-1-form");
    expect(form?.attrs).toMatchObject({ "data-week": "1", novalidate: "" });
    const label = form && find(form, (node) => node.tag === "label");
    expect(label?.attrs["for"]).toBe("week-1-text");
    expect(label && textOf(label)).toBe("Cosa vorresti cambiare?");
    const textarea = byId(tree, "week-1-text");
    expect(textarea?.attrs).toMatchObject({ name: "changes", maxlength: "1000", "data-week": "1", "aria-describedby": "week-1-hint week-1-count" });
    expect(textarea?.attrs["aria-invalid"]).toBeUndefined();
    expect(textarea?.children).toEqual(["Senza cipolla"]);
    expect(textOf(byId(tree, "week-1-hint") ?? "")).toContain("Non scrivere qui allergie, intolleranze o altri dati sulla salute");
    expect(textOf(byId(tree, "week-1-count") ?? "")).toBe("13/1000");
    expect(byId(tree, "week-1-submit")?.attrs["type"]).toBe("submit");
    expect(textOf(byId(tree, "week-1-submit") ?? "")).toBe("Invia la richiesta");
    expect(find(form ?? "", (node) => node.attrs["data-action"] === "close-changes")?.attrs["type"]).toBe("button");
  });

  it("un mensaje inválido: aria-invalid y el error, ligado al campo", () => {
    const tree = render(ready(), "it", { 1: { formOpen: true, textError: true } });
    const textarea = byId(tree, "week-1-text");
    expect(textarea?.attrs["aria-invalid"]).toBe("true");
    expect(textarea?.attrs["aria-describedby"]).toBe("week-1-hint week-1-count week-1-text-error");
    expect(textOf(byId(tree, "week-1-text-error") ?? "")).toBe("Scrivi cosa vorresti cambiare (al massimo 1000 caratteri).");
  });

  it("una miniatura que no cargó se pinta sin foto", () => {
    const tree = render(ready(), "it", {}, new Set([PHOTO.thumb]));
    expect(findAll(tree, (node) => node.tag === "img")).toEqual([]);
    expect(byClass(tree, "dish")[0]?.attrs["class"]).toBe("dish");
  });

  it("una reserva de una sola semana: «La tua settimana»; sin semanas, lo dice", () => {
    expect(texts(render(ready(view({ weeks: [week({ weeks: 1 })] }))), "week__title")).toEqual(["La tua settimana"]);
    expect(textOf(render(ready(view({ weeks: [] }))))).toContain("In questa prenotazione non ci sono settimane in programma.");
  });

  it("sin nombre de pila: saludo sin nombre", () => {
    expect(texts(render(ready(view({ clientFirstName: null }))), "reservation__greeting")).toEqual(["Ciao!"]);
  });
});

describe("página sin reserva", () => {
  it("cargando", () => {
    expect(textOf(render({ kind: "loading" }))).toBe("Sto caricando la tua prenotazione…");
  });

  it("link no válido: lo dice, sin datos, con un link a la portada", () => {
    const tree = render({ kind: "invalidLink" }, "es");
    const problem = byId(tree, "reservation-problem");
    expect(problem?.attrs["tabindex"]).toBe("-1");
    expect(texts(tree, "problem__title")).toEqual(["Este enlace no funciona"]);
    expect(texts(tree, "problem__text")[0]).toContain("Escribe a Evelyn");
    expect(find(tree, (node) => node.tag === "a")?.attrs["href"]).toBe("/");
  });

  it("error: el mensaje y «Riprova»", () => {
    const tree = render({ kind: "error", message: { key: "reservation.errors.rateLimitedMinutes", params: { minutes: 5 } } });
    expect(textOf(tree)).toContain("Troppi tentativi in poco tempo. Riprova tra circa 5 min.");
    expect(find(tree, (node) => node.attrs["data-action"] === "retry")?.tag).toBe("button");
  });
});

describe("piezas", () => {
  it("focusId: el id de cada cosa que recibe el foco", () => {
    expect(focusId({ kind: "status", week: 2 })).toBe("week-2-status");
    expect(focusId({ kind: "confirm", week: 1 })).toBe("week-1-confirm");
    expect(focusId({ kind: "askChanges", week: 1 })).toBe("week-1-changes");
    expect(focusId({ kind: "submit", week: 1 })).toBe("week-1-submit");
    expect(focusId({ kind: "textarea", week: 3 })).toBe("week-3-text");
    expect(focusId({ kind: "problem" })).toBe("reservation-problem");
  });

  it("messageText: con el nombre de la cocinera de la reserva (o Evelyn sin reserva)", () => {
    const message = { key: "reservation.notices.changesSent" } as const;
    expect(messageText(message, i18nFor("it"), ready(view({ chefName: "Giulia" })))).toContain("Giulia ha ricevuto");
    expect(messageText(message, i18nFor("it"), { kind: "loading" })).toContain("Evelyn ha ricevuto");
  });

  it("changesCountText", () => {
    expect(changesCountText(0, i18nFor("en"))).toBe("0/1000");
  });
});
