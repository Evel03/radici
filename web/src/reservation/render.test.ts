import { describe, expect, it } from "vitest";
import type { ClientLinkView } from "../../../supabase/functions/_shared/client_link.ts";
import type { Lang } from "../i18n/core.ts";
import { find, findAll, textOf, toHtml, type VNode } from "../lib/vdom.ts";
import { i18nFor } from "../request/fixtures.ts";
import type { Message, PageState, QuoteUi, WeekUi } from "./controller.ts";
import { PHOTO, SEND_1, SESSION_1, SESSION_2, content, menu, quoteView, resentQuoteView, view, week } from "./fixtures.ts";
import { DISH_PHOTO_SIZE, bookButtonId, changesCountText, focusId, messageText, reservationTree, weekDomId } from "./render.ts";

const NBSP = String.fromCharCode(0xa0);
const EMPTY_UI: WeekUi = { formOpen: false, draft: "", draftFor: null, busy: null, error: null, textError: null, notice: null };
const EMPTY_QUOTE_UI: QuoteUi = { declineOpen: false, declineFor: null, busy: null, error: null, declineError: null, notice: null };
const W1 = weekDomId(SESSION_1);
const W2 = weekDomId(SESSION_2);

interface RenderOptions {
  lang?: Lang;
  ui?: Partial<Record<string, Partial<WeekUi>>>;
  quoteUi?: Partial<QuoteUi>;
  failedPhotos?: ReadonlySet<string>;
  retrying?: boolean;
  pageNotice?: Message | null;
}

function render(state: PageState, options: RenderOptions = {}): VNode {
  return reservationTree({
    state,
    i18n: i18nFor(options.lang ?? "it"),
    ui: (session) => ({ ...EMPTY_UI, ...options.ui?.[session] }),
    quoteUi: { ...EMPTY_QUOTE_UI, ...options.quoteUi },
    retrying: options.retrying ?? false,
    pageNotice: options.pageNotice ?? null,
    ...(options.failedPhotos ? { failedPhotos: options.failedPhotos } : {}),
  });
}

const ready = (value: ClientLinkView = view()): PageState => ({ kind: "ready", view: value });
const byId = (tree: VNode, id: string): VNode | null => find(tree, (node) => node.attrs["id"] === id);
const byClass = (tree: VNode, cls: string): VNode[] => findAll(tree, (node) => (node.attrs["class"] ?? "").split(" ").includes(cls));
const texts = (tree: VNode, cls: string): string[] => byClass(tree, cls).map(textOf);
const statusText = (tree: VNode, id = W1): string => textOf(byId(tree, `${id}-status`) ?? "");

describe("la reserva, en italiano", () => {
  const tree = render(ready());

  it("saludo con el nombre de pila (enfocable, para «Riprova») y la presentación con la cocinera", () => {
    expect(texts(tree, "reservation__greeting")).toEqual(["Ciao Anna!"]);
    expect(byId(tree, "reservation-greeting")?.attrs["tabindex"]).toBe("-1");
    expect(texts(tree, "reservation__lead")[0]).toContain("con Evelyn");
  });

  it("cada semana: «Settimana k di N», la fecha y la hora de llegada, con los ids de su sesión", () => {
    expect(texts(tree, "week__title")).toEqual(["Settimana 1 di 2", "Settimana 2 di 2"]);
    expect(texts(tree, "week__when")).toEqual(["lunedì 1 marzo 2027 · arrivo alle 10:00", "lunedì 8 marzo 2027 · arrivo alle 10:00"]);
    expect(byId(tree, W1)?.tag).toBe("section");
    expect(byId(tree, W2)?.tag).toBe("section");
  });

  it("una semana sin menú dice que lo manda Evelyn", () => {
    const second = byId(tree, W2);
    expect(second && textOf(second)).toContain("Il menù di questa settimana te lo manda Evelyn nei prossimi giorni.");
    expect(second && byClass(second, "week__status")).toEqual([]);
  });

  it("el estado del menú: por confirmar, con el día del envío (en Roma, con el día de la semana y sin artículo)", () => {
    const status = byId(tree, `${W1}-status`);
    expect(status?.attrs["tabindex"]).toBe("-1");
    expect(status?.attrs["class"]).toBe("week__status week__status--pending");
    expect(statusText(tree)).toBe("Da confermare Evelyn ti ha mandato questo menù giovedì 25 febbraio 2027.");
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

  it("por confirmar: «Confermo il menù» y «Chiedo dei cambi», con la sesión de la semana", () => {
    const confirm = byId(tree, `${W1}-confirm`);
    expect(confirm?.attrs).toMatchObject({ type: "button", "data-action": "confirm", "data-session": SESSION_1 });
    expect(confirm && textOf(confirm)).toBe("Confermo il menù");
    expect(confirm?.attrs["aria-disabled"]).toBeUndefined();
    const changes = byId(tree, `${W1}-changes`);
    expect(changes?.attrs).toMatchObject({ "data-action": "open-changes", "data-session": SESSION_1 });
    expect(changes && textOf(changes)).toBe("Chiedo dei cambi");
  });

  it("nada de precios, pagos ni direcciones", () => {
    expect(toHtml(tree)).not.toMatch(/€|EUR|prezzo|pagament|indirizzo/i);
  });
});

describe("fechas en italiano: sin «il 1», «il 8» ni «il 11»", () => {
  it("con el día de la semana y sin artículo, también los días 1, 8 y 11", () => {
    const cases: Array<[string, string]> = [
      ["2027-03-01T10:00:00+01:00", "L'hai confermato lunedì 1 marzo 2027."],
      ["2027-03-08T10:00:00+01:00", "L'hai confermato lunedì 8 marzo 2027."],
      ["2027-03-11T10:00:00+01:00", "L'hai confermato giovedì 11 marzo 2027."],
    ];
    for (const [confirmedAt, expected] of cases) {
      const tree = render(ready(view({ weeks: [week({ menu: menu({ state: "confirmed", confirmedAt }) })] })));
      expect(statusText(tree)).toBe(`Confermato ${expected}`);
      expect(statusText(tree)).not.toMatch(/\bil \d/);
    }
  });
});

describe("en español y en inglés", () => {
  it("los textos, las fechas y las cantidades en el idioma de la página", () => {
    const es = render(ready(), { lang: "es" });
    expect(texts(es, "reservation__greeting")).toEqual(["¡Hola, Anna!"]);
    expect(texts(es, "week__title")).toEqual(["Semana 1 de 2", "Semana 2 de 2"]);
    expect(texts(es, "week__when")[0]).toBe("lunes, 1 de marzo de 2027 · llegada a las 10:00");
    expect(statusText(es)).toBe("Por confirmar Evelyn te mandó este menú el jueves, 25 de febrero de 2027.");
    expect(texts(es, "allergens__item")).toEqual(["gluten", "huevos", "leche y lácteos"]);
    expect(texts(es, "shopping__qty")).toEqual([`1,25${NBSP}kg`, `250${NBSP}g`, `1,5${NBSP}l`, "3 unidades"]);
    expect(texts(es, "shopping__section")).toEqual(["Fruta y verdura", "Lácteos y huevos", "Para tener en casa"]);

    const en = render(ready(), { lang: "en" });
    expect(texts(en, "reservation__greeting")).toEqual(["Hi Anna!"]);
    expect(texts(en, "week__title")[0]).toBe("Week 1 of 2");
    expect(texts(en, "week__when")[0]).toBe("Monday 1 March 2027 · arriving at 10:00");
    expect(statusText(en)).toBe("To confirm Evelyn sent you this menu on Thursday 25 February 2027.");
    expect(texts(en, "shopping__qty")).toEqual([`1.25${NBSP}kg`, `250${NBSP}g`, `1.5${NBSP}l`, "3 pieces"]);
    expect(textOf(byId(en, `${W1}-confirm`) ?? "")).toBe("I confirm the menu");
  });

  it("los textos del envío conservan su idioma (lang) si la página está en otro", () => {
    const es = render(ready(), { lang: "es" });
    for (const cls of ["dish__name", "dish__desc", "shopping__name", "menu__note"]) {
      for (const node of byClass(es, cls)) expect(node.attrs["lang"], cls).toBe("it");
    }
    // En el mismo idioma, sin lang de más.
    const it = render(ready(), { lang: "it" });
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
    expect(statusText(tree)).toBe("Confermato L'hai confermato venerdì 26 febbraio 2027.");
    expect(byId(tree, `${W1}-confirm`)).toBeNull();
    expect(byId(tree, `${W1}-changes`)).toBeNull();
    expect(byClass(tree, "week__status")[0]?.attrs["class"]).toBe("week__status week__status--confirmed");
  });

  it("con cambios pedidos: sin botones, dice que Evelyn lo manda de nuevo", () => {
    const tree = render(ready(view({ weeks: [week({ menu: menu({ state: "changesRequested", changesRequestedAt: "2027-02-26T10:00:00+00:00" }) })] })));
    expect(statusText(tree)).toBe("Cambi chiesti Hai chiesto dei cambi venerdì 26 febbraio 2027: Evelyn ti manderà il menù di nuovo.");
    expect(byId(tree, `${W1}-confirm`)).toBeNull();
    expect(byId(tree, `${W1}-form`)).toBeNull();
  });

  it("un envío que no se puede mostrar (semana sin cocinar): estado neutro, lo dice (Evelyn lo reenvía) y no deja contestar", () => {
    const tree = render(ready(view({ weeks: [week({ menu: menu({ content: null }) })] })));
    expect(byClass(tree, "week__status")[0]?.attrs["class"]).toBe("week__status week__status--sent");
    expect(statusText(tree)).toBe("Inviato Evelyn ti ha mandato questo menù giovedì 25 febbraio 2027.");
    expect(textOf(tree)).toContain("Non riusciamo a mostrare qui questo menù. Scrivi a Evelyn: te lo rimanda.");
    expect(byId(tree, `${W1}-confirm`)).toBeNull();
    expect(byClass(tree, "dish")).toEqual([]);
  });

  it("el aviso de la última respuesta va en el estado (que recibe el foco)", () => {
    const tree = render(ready(view({ weeks: [week({ menu: menu({ state: "confirmed", confirmedAt: "2027-02-26T10:00:00+00:00" }) })] })), {
      ui: { [SESSION_1]: { notice: { key: "reservation.notices.confirmed" } } },
    });
    const status = byId(tree, `${W1}-status`);
    expect(status && texts(status, "week__notice")).toEqual(["Grazie! Abbiamo avvisato Evelyn."]);
  });

  it("con una respuesta en camino: los botones quedan aria-disabled (conservan el foco) y dicen «Un momento…»", () => {
    const tree = render(ready(), { ui: { [SESSION_1]: { busy: "confirm" } } });
    expect(byId(tree, `${W1}-confirm`)?.attrs["aria-disabled"]).toBe("true");
    expect(byId(tree, `${W1}-confirm`)?.attrs["disabled"]).toBeUndefined();
    expect(textOf(byId(tree, `${W1}-confirm`) ?? "")).toBe("Un momento…");
    expect(byId(tree, `${W1}-changes`)?.attrs["aria-disabled"]).toBe("true");
  });

  it("un error de la última respuesta, junto a los botones", () => {
    const tree = render(ready(), { ui: { [SESSION_1]: { error: { key: "reservation.errors.network" } } } });
    expect(textOf(byId(tree, `${W1}-error`) ?? "")).toBe("Non riusciamo a collegarci. Controlla la connessione e riprova.");
  });

  it("el formulario de cambios: etiqueta, aviso de no escribir datos de salud, tope, contador y botones", () => {
    const tree = render(ready(), { ui: { [SESSION_1]: { formOpen: true, draft: "Senza cipolla" } } });
    expect(byId(tree, `${W1}-confirm`)).toBeNull();
    const form = byId(tree, `${W1}-form`);
    expect(form?.attrs).toMatchObject({ "data-session": SESSION_1, novalidate: "" });
    const label = form && find(form, (node) => node.tag === "label");
    expect(label?.attrs["for"]).toBe(`${W1}-text`);
    expect(label && textOf(label)).toBe("Cosa vorresti cambiare?");
    const textarea = byId(tree, `${W1}-text`);
    expect(textarea?.attrs).toMatchObject({ name: "changes", maxlength: "1000", "data-session": SESSION_1, "aria-describedby": `${W1}-hint ${W1}-count` });
    expect(textarea?.attrs["aria-invalid"]).toBeUndefined();
    expect(textarea?.children).toEqual(["Senza cipolla"]);
    expect(textOf(byId(tree, `${W1}-hint`) ?? "")).toContain("Non scrivere qui allergie, intolleranze o altri dati sulla salute");
    expect(textOf(byId(tree, `${W1}-count`) ?? "")).toBe("13/1000");
    expect(byId(tree, `${W1}-submit`)?.attrs["type"]).toBe("submit");
    expect(textOf(byId(tree, `${W1}-submit`) ?? "")).toBe("Invia la richiesta");
    expect(find(form ?? "", (node) => node.attrs["data-action"] === "close-changes")?.attrs).toMatchObject({ type: "button", "data-session": SESSION_1 });
  });

  it("un mensaje inválido: aria-invalid y el error que corresponde (vacío, largo o no aceptado), ligado al campo", () => {
    const expected = {
      empty: "Scrivi cosa vorresti cambiare.",
      tooLong: "Puoi scrivere al massimo 1000 caratteri.",
      invalid: "Non siamo riusciti a ricevere questo messaggio. Prova a riscriverlo oppure scrivi direttamente a Evelyn.",
    } as const;
    for (const textError of ["empty", "tooLong", "invalid"] as const) {
      const tree = render(ready(), { ui: { [SESSION_1]: { formOpen: true, textError } } });
      const textarea = byId(tree, `${W1}-text`);
      expect(textarea?.attrs["aria-invalid"]).toBe("true");
      expect(textarea?.attrs["aria-describedby"]).toBe(`${W1}-hint ${W1}-count ${W1}-text-error`);
      expect(textOf(byId(tree, `${W1}-text-error`) ?? "")).toBe(expected[textError]);
    }
  });

  it("una miniatura que no cargó se pinta sin foto", () => {
    const tree = render(ready(), { failedPhotos: new Set([PHOTO.thumb]) });
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

describe("una semana ya cocinada no promete nada", () => {
  const done = (overrides: Parameters<typeof week>[0]) => render(ready(view({ weeks: [week({ done: true, ...overrides })] })));

  it("sin menú: solo que ya cocinó (nada de «te lo manda en los próximos días»)", () => {
    const tree = done({ menu: null });
    expect(texts(tree, "week__done")).toEqual(["Evelyn ha già cucinato questa settimana."]);
    expect(textOf(tree)).not.toContain("nei prossimi giorni");
    expect(byClass(tree, "week__status")).toEqual([]);
  });

  it("con el menú por confirmar: enviado, neutro, sin «Da confermare» ni botones", () => {
    const tree = done({});
    expect(byClass(tree, "week__status")[0]?.attrs["class"]).toBe("week__status week__status--sent");
    expect(statusText(tree)).toBe("Inviato Evelyn ti ha mandato questo menù giovedì 25 febbraio 2027.");
    expect(textOf(tree)).not.toContain("Da confermare");
    expect(byClass(tree, "dish")).toHaveLength(2);
    expect(byId(tree, `${W1}-confirm`)).toBeNull();
  });

  it("con cambios pedidos: sin la promesa de reenvío", () => {
    const tree = done({ menu: menu({ state: "changesRequested", changesRequestedAt: "2027-02-26T10:00:00+00:00" }) });
    expect(statusText(tree)).toBe("Cambi chiesti Hai chiesto dei cambi venerdì 26 febbraio 2027.");
    expect(textOf(tree)).not.toContain("di nuovo");
  });

  it("con un envío que no se puede mostrar: sin «te lo rimanda»", () => {
    const tree = done({ menu: menu({ content: null }) });
    expect(textOf(tree)).toContain("Non riusciamo a mostrare qui questo menù.");
    expect(textOf(tree)).not.toContain("rimanda");
    expect(statusText(tree)).toBe("Inviato Evelyn ti ha mandato questo menù giovedì 25 febbraio 2027.");
  });

  it("confirmado: igual que siempre", () => {
    const tree = done({ menu: menu({ state: "confirmed", confirmedAt: "2027-02-26T10:00:00+00:00" }) });
    expect(statusText(tree)).toBe("Confermato L'hai confermato venerdì 26 febbraio 2027.");
  });
});

describe("aviso de la página", () => {
  it("una semana que se canceló: arriba, con su fecha en el idioma de la página, enfocable", () => {
    const pageNotice: Message = { key: "reservation.notices.sessionCancelled", date: "2027-03-08" };
    const it = render(ready(), { pageNotice });
    const notice = byId(it, "reservation-notice");
    expect(notice?.attrs["tabindex"]).toBe("-1");
    expect(notice && textOf(notice)).toBe(
      "La settimana di lunedì 8 marzo 2027 è stata cancellata, quindi non puoi più rispondere al suo menù. Per qualsiasi dubbio scrivi a Evelyn.",
    );
    const es = render(ready(), { lang: "es", pageNotice });
    expect(textOf(byId(es, "reservation-notice") ?? "")).toBe(
      "La semana del lunes, 8 de marzo de 2027 se canceló, así que ya no puedes responder a su menú. Si tienes alguna duda, escribe a Evelyn.",
    );
    expect(byId(render(ready()), "reservation-notice")).toBeNull();
  });

  it("una respuesta que no salió porque el presupuesto de ese menú se cerró (y su semana ya no está): arriba, con la fecha", () => {
    const pageNotice: Message = { key: "reservation.notices.quoteClosedGone", date: "2027-03-01" };
    const expected: Record<Lang, string> = {
      it: "La tua risposta al menù di lunedì 1 marzo 2027 non è stata inviata: il preventivo con cui era arrivato non è più valido. Per qualsiasi dubbio scrivi a Evelyn.",
      es: "Tu respuesta al menú del lunes, 1 de marzo de 2027 no se envió: el presupuesto con el que llegó ya no es válido. Si tienes alguna duda, escribe a Evelyn.",
      en: "Your reply to the menu for Monday 1 March 2027 wasn't sent: the quote it came with is no longer valid. If you have any questions, write to Evelyn.",
    };
    for (const lang of ["it", "es", "en"] as const) {
      const tree = render(ready(view({ weeks: [] })), { lang, pageNotice });
      expect(textOf(byId(tree, "reservation-notice") ?? ""), lang).toBe(expected[lang]);
    }
  });

  it("una respuesta al presupuesto que no se registró porque el presupuesto ya no está: arriba, dice por qué (Evelyn confirmó la reserva o mandó otro)", () => {
    const expected: Record<"goneBooked" | "goneReplaced", Record<Lang, string>> = {
      goneBooked: {
        it: "Non abbiamo potuto registrare la tua risposta al preventivo: nel frattempo Evelyn ha confermato direttamente la tua prenotazione. Per qualsiasi dubbio scrivi a Evelyn.",
        es: "No pudimos registrar tu respuesta al presupuesto: mientras tanto, Evelyn confirmó directamente tu reserva. Si tienes alguna duda, escribe a Evelyn.",
        en: "We couldn't record your answer to the quote: in the meantime, Evelyn confirmed your booking directly. If you have any questions, write to Evelyn.",
      },
      goneReplaced: {
        it: "Non abbiamo potuto registrare la tua risposta: nel frattempo Evelyn ti ha mandato un nuovo preventivo, che trovi qui sotto.",
        es: "No pudimos registrar tu respuesta: mientras tanto, Evelyn te mandó un presupuesto nuevo, que tienes aquí abajo.",
        en: "We couldn't record your answer: in the meantime, Evelyn sent you a new quote, which you'll find below.",
      },
    };
    const NEW_QUOTE = "9a0e0000-0000-4000-8000-000000000002";
    for (const lang of ["it", "es", "en"] as const) {
      // Confirmada sin el presupuesto: /view ya no lo trae, así que no hay recuadro.
      const booked = render(ready(view()), { lang, pageNotice: { key: "reservation.quote.notices.goneBooked" } });
      expect(textOf(byId(booked, "reservation-notice") ?? ""), lang).toBe(expected.goneBooked[lang]);
      expect(byId(booked, "quote"), lang).toBeNull();
      // Otro presupuesto: el aviso, arriba del recuadro nuevo («qui sotto»).
      const replaced = render(ready(quoteView({ id: NEW_QUOTE, version: 2 }, { quoteId: NEW_QUOTE })), {
        lang,
        pageNotice: { key: "reservation.quote.notices.goneReplaced" },
      });
      expect(textOf(byId(replaced, "reservation-notice") ?? ""), lang).toBe(expected.goneReplaced[lang]);
      const html = toHtml(replaced);
      expect(html.indexOf('id="reservation-notice"'), lang).toBeLessThan(html.indexOf('id="quote"'));
      expect(html.indexOf('id="quote"'), lang).toBeGreaterThan(-1);
    }
  });
});

describe("página sin reserva", () => {
  it("cargando", () => {
    expect(textOf(render({ kind: "loading" }))).toBe("Sto caricando la tua prenotazione…");
  });

  it("link no válido: lo dice, sin datos, con un link a la portada", () => {
    const tree = render({ kind: "invalidLink" }, { lang: "es" });
    const problem = byId(tree, "reservation-problem");
    expect(problem?.attrs["tabindex"]).toBe("-1");
    expect(texts(tree, "problem__title")).toEqual(["Este enlace no funciona"]);
    expect(texts(tree, "problem__text")[0]).toContain("Escribe a Evelyn");
    expect(find(tree, (node) => node.tag === "a")?.attrs["href"]).toBe("/");
  });

  it("error: el mensaje y «Riprova» (con id); mientras reintenta, aria-disabled y «Riprovo…»", () => {
    const state: PageState = { kind: "error", message: { key: "reservation.errors.rateLimitedMinutes", params: { minutes: 5 } } };
    const tree = render(state);
    expect(textOf(tree)).toContain("Troppi tentativi in poco tempo. Riprova tra circa 5 min.");
    const retry = byId(tree, "reservation-retry");
    expect(retry?.attrs).toMatchObject({ "data-action": "retry", type: "button" });
    expect(retry?.attrs["aria-disabled"]).toBeUndefined();
    expect(retry && textOf(retry)).toBe("Riprova");
    const busy = byId(render(state, { retrying: true }), "reservation-retry");
    expect(busy?.attrs["aria-disabled"]).toBe("true");
    expect(busy && textOf(busy)).toBe("Riprovo…");
  });
});

describe("piezas", () => {
  it("focusId: el id de cada cosa que recibe el foco", () => {
    expect(focusId({ kind: "status", session: SESSION_2 })).toBe(`${W2}-status`);
    expect(focusId({ kind: "confirm", session: SESSION_1 })).toBe(`${W1}-confirm`);
    expect(focusId({ kind: "askChanges", session: SESSION_1 })).toBe(`${W1}-changes`);
    expect(focusId({ kind: "submit", session: SESSION_1 })).toBe(`${W1}-submit`);
    expect(focusId({ kind: "textarea", session: SESSION_1 })).toBe(`${W1}-text`);
    expect(focusId({ kind: "problem" })).toBe("reservation-problem");
    expect(focusId({ kind: "greeting" })).toBe("reservation-greeting");
    expect(focusId({ kind: "notice" })).toBe("reservation-notice");
  });

  it("messageText: con el nombre de la cocinera de la reserva (o Evelyn sin reserva) y la fecha larga", () => {
    const message = { key: "reservation.notices.changesSent" } as const;
    expect(messageText(message, i18nFor("it"), ready(view({ chefName: "Giulia" })))).toBe("Fatto: Giulia ha ricevuto la tua richiesta.");
    expect(messageText(message, i18nFor("it"), { kind: "loading" })).toBe("Fatto: Evelyn ha ricevuto la tua richiesta.");
    expect(messageText({ key: "reservation.notices.sessionCancelled", date: "2027-03-01" }, i18nFor("en"), ready())).toContain(
      "The week of Monday 1 March 2027 was cancelled",
    );
  });

  it("changesCountText", () => {
    expect(changesCountText(0, i18nFor("en"))).toBe("0/1000");
  });
});

describe("el libro del menú en cada semana", () => {
  it("una semana con el menú: «Sfoglia il menù», que abre su libro (data-action open-book, con su id)", () => {
    const tree = render(ready());
    const button = byId(tree, bookButtonId(SESSION_1));
    expect(button?.attrs).toEqual({
      class: "btn btn--ghost week__book",
      type: "button",
      id: `${W1}-book`,
      "data-action": "open-book",
      "data-session": SESSION_1,
    });
    expect(button && textOf(button)).toBe("Sfoglia il menù");
    expect(textOf(byId(render(ready(), { lang: "es" }), bookButtonId(SESSION_1)) ?? "")).toBe("Hojea el menú");
    expect(textOf(byId(render(ready(), { lang: "en" }), bookButtonId(SESSION_1)) ?? "")).toBe("Browse the menu");
  });

  it("también confirmada o ya cocinada (el libro se puede volver a hojear); sin menú o con uno que no se lee, no", () => {
    const confirmed = view({
      weeks: [week({ done: true, menu: menu({ state: "confirmed", confirmedAt: "2027-02-26T10:00:00Z" }) }), week({ sessionId: SESSION_2, week: 2, menu: menu({ content: null }) })],
    });
    const tree = render(ready(confirmed));
    expect(byId(tree, bookButtonId(SESSION_1))).not.toBeNull();
    expect(byId(tree, bookButtonId(SESSION_2))).toBeNull();
    expect(byId(render(ready()), bookButtonId(SESSION_2))).toBeNull();
  });
});

// ---------------------------------------------------------------------------
// El presupuesto (SPEC 5.8)
// ---------------------------------------------------------------------------

/** El texto con los espacios duros como espacios (los importes de Intl los llevan entre el número y el €). */
const plain = (text: string): string => text.replace(/[  ]/g, " ");
const quoteStatusText = (tree: VNode): string => plain(textOf(byId(tree, "quote-status") ?? ""));

describe("el presupuesto, por aceptar (en italiano)", () => {
  const tree = render(ready(quoteView()));

  it("arriba de las semanas, con la presentación del presupuesto", () => {
    const content = find(tree, (node) => (node.attrs["class"] ?? "") === "reservation__content");
    const order = (content?.children ?? []).map((child) => (typeof child === "string" ? child : (child.attrs["class"] ?? "")));
    expect(order.indexOf("quote quote--pending")).toBeGreaterThan(-1);
    expect(order.indexOf("quote quote--pending")).toBeLessThan(order.indexOf("weeks"));
    expect(texts(tree, "reservation__lead")[0]).toBe(
      "Qui trovi il preventivo di Evelyn, con le settimane che ti propone e il menù della prima. Accettalo, oppure chiedi dei cambi.",
    );
    expect(byId(tree, "quote")?.attrs["aria-labelledby"]).toBe("quote-title");
    expect(textOf(byId(tree, "quote-title") ?? "")).toBe("Il tuo preventivo");
    expect(byClass(tree, "quote__version"), "la versión 1 no lo dice").toEqual([]);
  });

  it("el estado: por aceptar, hasta cuándo (el plazo en Roma, día y hora) y que las fechas quedan reservadas", () => {
    const status = byId(tree, "quote-status");
    expect(status?.attrs["tabindex"]).toBe("-1");
    expect(status?.attrs["class"]).toBe("quote__status quote__status--pending");
    expect(quoteStatusText(tree)).toBe(
      "Da accettare Puoi accettarlo fino a sabato 27 febbraio 2027 alle 19:03. Fino ad allora queste date restano riservate per te.",
    );
  });

  it("lo que vio: cada semana con su llegada y su precio, y el total del servicio", () => {
    const rows = byClass(tree, "quote__week").map((row) => [
      texts(row, "quote__week-label")[0],
      texts(row, "quote__week-when")[0],
      plain(texts(row, "quote__week-price")[0] ?? ""),
    ]);
    expect(rows).toEqual([
      ["Settimana 1", "lunedì 1 marzo 2027 · arrivo alle 10:00", "150,00 €"],
      ["Settimana 2", "lunedì 8 marzo 2027 · arrivo alle 10:00", "150,00 €"],
    ]);
    expect(texts(tree, "quote__total-label")).toEqual(["Totale del servizio"]);
    expect(texts(tree, "quote__total-value").map(plain)).toEqual(["300,00 €"]);
  });

  it("«Accetto il preventivo» (que confirma también el menú de la semana 1) y «Rifiuto»; los cambios, en el menú", () => {
    const accept = byId(tree, "quote-accept");
    expect(accept?.attrs).toMatchObject({ type: "button", "data-action": "accept-quote", class: "btn btn--primary" });
    expect(accept?.attrs["aria-disabled"]).toBeUndefined();
    expect(textOf(accept ?? "")).toBe("Accetto il preventivo");
    expect(textOf(byId(tree, "quote-decline") ?? "")).toBe("Rifiuto");
    expect(byId(tree, "quote-decline")?.attrs["data-action"]).toBe("decline-quote");
    expect(texts(tree, "quote__hint")).toEqual(["Accettando il preventivo confermi anche il menù della prima settimana."]);
    expect(texts(tree, "quote__more")).toEqual(["Vuoi cambiare qualcosa? Scrivilo con «Chiedo dei cambi», nel menù qui sotto."]);
  });

  it("la semana 1: el menú va con el presupuesto, sin «Confermo il menù» (sí «Chiedo dei cambi»)", () => {
    expect(statusText(tree)).toBe(
      "Con il preventivo Evelyn ti ha mandato questo menù insieme al preventivo giovedì 25 febbraio 2027. Lo confermi quando accetti il preventivo, qui sopra.",
    );
    expect(byClass(tree, "week__status")[0]?.attrs["class"]).toBe("week__status week__status--pending");
    expect(byId(tree, `${W1}-confirm`)).toBeNull();
    expect(byId(tree, `${W1}-changes`)?.attrs).toMatchObject({ "data-action": "open-changes", "data-session": SESSION_1 });
    expect(byClass(tree, "dish"), "el menú se ve entero").toHaveLength(2);
  });

  it("los precios, solo en el recuadro del presupuesto; nada de pagos en ningún lado", () => {
    const weeks = find(tree, (node) => node.attrs["class"] === "weeks");
    expect(toHtml(weeks ?? "")).not.toMatch(/€|EUR|prezzo/i);
    expect(toHtml(tree)).not.toMatch(/pagament|bonifico|contanti|carta di credito|payment|pago/i);
  });
});

describe("el presupuesto: estados", () => {
  it("con cambios pedidos a esta versión: lo dice, sin «Accetto»; «Rifiuto» sigue (la base lo deja)", () => {
    const tree = render(ready(quoteView({}, { state: "changesRequested", changesRequestedAt: "2027-02-26T10:00:00+00:00" })));
    expect(quoteStatusText(tree)).toBe("Cambi chiesti Hai chiesto dei cambi venerdì 26 febbraio 2027: Evelyn ti manderà il preventivo aggiornato.");
    expect(byId(tree, "quote-accept")).toBeNull();
    expect(byId(tree, "quote-decline")).not.toBeNull();
    expect(byClass(tree, "quote__week"), "lo que vio sigue a la vista").toHaveLength(2);
    expect(byClass(tree, "quote__more")).toEqual([]);
  });

  it("cambiado sin reenviar: Evelyn prepara otra versión; sin precios ni botones", () => {
    const tree = render(ready(quoteView({ status: "changed" })));
    expect(quoteStatusText(tree)).toBe("In aggiornamento Evelyn sta preparando una nuova versione di questo preventivo: te la manda presto.");
    expect(byClass(tree, "quote__week")).toEqual([]);
    expect(byId(tree, "quote-accept")).toBeNull();
    expect(byId(tree, "quote-decline")).toBeNull();
    // El menú sigue yendo con el presupuesto: sin «Confermo».
    expect(byId(tree, `${W1}-confirm`)).toBeNull();
    expect(texts(tree, "reservation__lead")[0]).toContain("il preventivo di Evelyn");
  });

  it("aceptado: el día y lo que aceptó; el menú de la semana 1, confirmado; sin botones", () => {
    const tree = render(
      ready(quoteView({ status: "accepted", acceptedAt: "2027-02-26T10:00:00+00:00" }, { state: "confirmed", confirmedAt: "2027-02-26T10:00:00+00:00" })),
    );
    expect(byId(tree, "quote")?.attrs["class"]).toBe("quote quote--accepted");
    expect(quoteStatusText(tree)).toBe("Accettato L'hai accettato venerdì 26 febbraio 2027.");
    expect(texts(tree, "quote__total-value").map(plain)).toEqual(["300,00 €"]);
    expect(byId(tree, "quote-accept")).toBeNull();
    expect(byId(tree, "quote-decline")).toBeNull();
    expect(statusText(tree)).toBe("Confermato L'hai confermato venerdì 26 febbraio 2027.");
    expect(texts(tree, "reservation__lead")[0]).toContain("Qui trovi le settimane della tua prenotazione");
  });

  it("rechazado, retirado y vencido: lo dicen, sin precios ni botones; el menú que iba con él, sin botones", () => {
    const cases = [
      ["declined", "Rifiutato Hai rifiutato questo preventivo. Se cambi idea, scrivi a Evelyn."],
      ["withdrawn", "Ritirato Questo preventivo è stato ritirato. Per qualsiasi dubbio scrivi a Evelyn."],
      [
        "expired",
        "Scaduto Il tempo per accettare questo preventivo è finito. Se ti interessa ancora, scrivi a Evelyn: ti prepara un nuovo preventivo.",
      ],
    ] as const;
    for (const [status, expected] of cases) {
      const tree = render(ready(quoteView({ status })));
      expect(byId(tree, "quote")?.attrs["class"], status).toBe("quote quote--closed");
      expect(quoteStatusText(tree), status).toBe(expected);
      expect(byClass(tree, "quote__week"), status).toEqual([]);
      // Sin botones de contestar: solo queda «Sfoglia il menù» (el libro se puede hojear, no contesta nada).
      expect(findAll(tree, (node) => node.tag === "button" && node.attrs["data-action"] !== "open-book"), status).toEqual([]);
      expect(statusText(tree), status).toBe("Inviato Evelyn ti ha mandato questo menù insieme al preventivo giovedì 25 febbraio 2027.");
    }
  });

  it("una versión nueva lo dice; uno que no se puede mostrar, tampoco se contesta", () => {
    expect(texts(render(ready(quoteView({ version: 2 }))), "quote__version")).toEqual(["Versione 2"]);
    const unreadable = render(ready(quoteView({ summary: null })));
    expect(quoteStatusText(unreadable)).toBe("Da accettare Non riusciamo a mostrare qui questo preventivo. Scrivi a Evelyn: te lo rimanda.");
    expect(findAll(unreadable, (node) => (node.attrs["id"] ?? "").startsWith("quote-") && node.tag === "button")).toEqual([]);
  });

  it("una sola semana: sin «Settimana 1» ni precio por semana; «Prezzo del servizio»; la presentación, el plazo y la pregunta en singular", () => {
    const single = quoteView({ summary: { totalCents: 15000, weeks: [{ date: "2027-03-01", start: "10:00", serviceCents: 15000 }] } });
    const tree = render(ready(single));
    expect(byClass(tree, "quote__week-label")).toEqual([]);
    expect(byClass(tree, "quote__week-price")).toEqual([]);
    expect(texts(tree, "quote__total-label")).toEqual(["Prezzo del servizio"]);
    expect(texts(tree, "quote__hint")).toEqual(["Accettando il preventivo confermi anche il menù."]);
    expect(texts(tree, "reservation__lead")).toEqual([
      "Qui trovi il preventivo di Evelyn, con la data che ti propone e il suo menù. Accettalo, oppure chiedi dei cambi.",
    ]);
    expect(quoteStatusText(tree)).toBe("Da accettare Puoi accettarlo fino a sabato 27 febbraio 2027 alle 19:03. Fino ad allora questa data resta riservata per te.");
    const question = (lang: Lang): string =>
      textOf(byId(render(ready(single), { lang, quoteUi: { declineOpen: true, declineFor: SEND_1 } }), "quote-decline-question") ?? "");
    expect(question("it")).toBe("Vuoi rifiutare il preventivo? La data proposta non sarà più riservata per te e da qui non potrai più accettarlo.");

    const expected: Record<"es" | "en", { lead: string; state: string; question: string }> = {
      es: {
        lead: "Aquí tienes el presupuesto de Evelyn, con la fecha que te propone y su menú. Acéptalo, o pide cambios.",
        state: "Por aceptar Puedes aceptarlo hasta el sábado, 27 de febrero de 2027 a las 19:03. Hasta entonces, esta fecha queda reservada para ti.",
        question: "¿Quieres rechazar el presupuesto? La fecha propuesta dejará de estar reservada para ti y ya no podrás aceptarlo desde aquí.",
      },
      en: {
        lead: "Here you'll find Evelyn's quote, with the proposed date and its menu. Accept it, or ask for changes.",
        state: "To accept You can accept it until Saturday 27 February 2027 at 19:03. Until then, this date is held for you.",
        question: "Do you want to decline the quote? The proposed date will no longer be held for you and you won't be able to accept it from here.",
      },
    };
    for (const lang of ["es", "en"] as const) {
      const other = render(ready(single), { lang });
      expect(texts(other, "reservation__lead"), lang).toEqual([expected[lang].lead]);
      expect(quoteStatusText(other), lang).toBe(expected[lang].state);
      expect(question(lang), lang).toBe(expected[lang].question);
    }
    // Ninguna de las tres en plural con una sola semana.
    for (const lang of ["it", "es", "en"] as const) {
      const html = toHtml(render(ready(single), { lang, quoteUi: { declineOpen: true, declineFor: SEND_1 } }));
      expect(html, lang).not.toMatch(/settimane che|queste date|date proposte|las semanas que|estas fechas|fechas propuestas|proposed weeks|these dates|proposed dates/);
    }
  });

  it("cambiado (sin lo que vio): la presentación cuenta las semanas de la reserva", () => {
    const changed = quoteView({ status: "changed", summary: null });
    const one = { ...changed, weeks: changed.weeks.slice(0, 1).map((item) => ({ ...item, weeks: 1 })) };
    expect(texts(render(ready(one)), "reservation__lead")[0]).toContain("con la data che ti propone");
    expect(texts(render(ready(changed)), "reservation__lead")[0]).toContain("con le settimane che ti propone");
  });

  it("sin plazo: cuándo se lo mandó", () => {
    const tree = render(ready(quoteView({ holdUntil: null })));
    expect(quoteStatusText(tree)).toBe("Da accettare Evelyn ti ha mandato questo preventivo giovedì 25 febbraio 2027.");
  });
});

describe("el presupuesto: un envío anterior que quedó en otra semana (la semana 1 pasó al final y Evelyn lo reenvió)", () => {
  const W_OLD = weekDomId(SESSION_1);
  const W_NEW = weekDomId(SESSION_2);

  it("mientras está abierto: sin «Confermo» ni la promesa de confirmarlo al aceptar; dice que va con una versión anterior y deja pedir cambios", () => {
    const tree = render(ready(resentQuoteView()));
    expect(statusText(tree, W_OLD)).toBe(
      "Inviato Evelyn ti ha mandato questo menù giovedì 25 febbraio 2027, con una versione precedente del preventivo. Potrai confermarlo dopo aver accettato il preventivo, qui sopra.",
    );
    expect(byId(tree, `${W_OLD}-status`)?.attrs["class"]).toBe("week__status week__status--sent");
    expect(byId(tree, `${W_OLD}-confirm`)).toBeNull();
    expect(byId(tree, `${W_OLD}-changes`)?.attrs).toMatchObject({ "data-action": "open-changes", "data-session": SESSION_1 });
    expect(statusText(tree, W_OLD)).not.toContain("Lo confermi quando accetti");
    // El envío que lleva el presupuesto (la nueva semana 1) sigue como siempre.
    expect(statusText(tree, W_NEW)).toContain("Lo confermi quando accetti il preventivo, qui sopra.");
    expect(byId(tree, `${W_NEW}-confirm`)).toBeNull();
    expect(byId(tree, "quote-accept")).not.toBeNull();
  });

  it("en español y en inglés, sus textos", () => {
    expect(statusText(render(ready(resentQuoteView()), { lang: "es" }), W_OLD)).toBe(
      "Enviado Evelyn te mandó este menú el jueves, 25 de febrero de 2027, con una versión anterior del presupuesto. Podrás confirmarlo cuando hayas aceptado el presupuesto, aquí arriba.",
    );
    expect(statusText(render(ready(resentQuoteView()), { lang: "en" }), W_OLD)).toBe(
      "Sent Evelyn sent you this menu on Thursday 25 February 2027, with an earlier version of the quote. You'll be able to confirm it once you've accepted the quote, above.",
    );
  });

  it("aceptado el presupuesto: se confirma o se le piden cambios como cualquier menú", () => {
    const accepted = resentQuoteView({ status: "accepted", acceptedAt: "2027-02-26T12:00:00+00:00" });
    const confirmedNew = {
      ...accepted,
      weeks: accepted.weeks.map((item) =>
        item.sessionId === SESSION_2 && item.menu ? { ...item, menu: { ...item.menu, state: "confirmed" as const, confirmedAt: "2027-02-26T12:00:00+00:00" } } : item,
      ),
    };
    const tree = render(ready(confirmedNew));
    expect(statusText(tree, W_OLD)).toBe("Da confermare Evelyn ti ha mandato questo menù giovedì 25 febbraio 2027.");
    expect(textOf(byId(tree, `${W_OLD}-confirm`) ?? "")).toBe("Confermo il menù");
    expect(byId(tree, `${W_OLD}-changes`)).not.toBeNull();
    expect(statusText(tree, W_NEW)).toBe("Confermato L'hai confermato venerdì 26 febbraio 2027.");
  });

  it("con cambios pedidos a ese envío: Evelyn lo manda de nuevo", () => {
    const tree = render(ready(resentQuoteView({}, { state: "changesRequested", changesRequestedAt: "2027-02-26T10:00:00+00:00" })));
    expect(statusText(tree, W_OLD)).toBe("Cambi chiesti Hai chiesto dei cambi venerdì 26 febbraio 2027: Evelyn ti manderà il menù di nuovo.");
  });
});

describe("el presupuesto: acciones", () => {
  it("la confirmación del rechazo: debajo de «Rifiuto», la pregunta (enfocable), «No, torna indietro» y «Sì, rifiuto il preventivo»", () => {
    const tree = render(ready(quoteView()), { quoteUi: { declineOpen: true, declineFor: SEND_1 } });
    const question = byId(tree, "quote-decline-question");
    expect(question?.attrs["tabindex"]).toBe("-1");
    expect(textOf(question ?? "")).toBe(
      "Vuoi rifiutare il preventivo? Le date proposte non saranno più riservate per te e da qui non potrai più accettarlo.",
    );
    const group = find(tree, (node) => node.attrs["role"] === "group");
    expect(group?.attrs).toMatchObject({ id: "quote-confirm", "aria-labelledby": "quote-decline-question" });
    expect(byId(tree, "quote-decline-confirm")?.attrs).toMatchObject({ "data-action": "decline-quote-confirm", class: "btn btn--danger" });
    expect(textOf(byId(tree, "quote-decline-confirm") ?? "")).toBe("Sì, rifiuto il preventivo");
    expect(byId(tree, "quote-decline-cancel")?.attrs["data-action"]).toBe("decline-quote-cancel");
    expect(textOf(byId(tree, "quote-decline-cancel") ?? "")).toBe("No, torna indietro");
    // «Rifiuto» sigue ahí, abierto (lo cierra), y «Accetto» también: nada de lo de arriba se mueve.
    expect(byId(tree, "quote-decline")?.attrs).toMatchObject({ "data-action": "decline-quote", "aria-expanded": "true", "aria-controls": "quote-confirm" });
    expect(textOf(byId(tree, "quote-accept") ?? "")).toBe("Accetto il preventivo");
    expect(byClass(tree, "quote__more"), "la ayuda de los cambios no va mientras pregunta").toEqual([]);
    const closed = render(ready(quoteView()));
    expect(byId(closed, "quote-decline")?.attrs["aria-expanded"]).toBe("false");
    expect(byId(closed, "quote-decline")?.attrs["aria-controls"]).toBeUndefined();
    expect(find(closed, (node) => node.attrs["role"] === "group")).toBeNull();
  });

  it("un doble toque en «Rifiuto» no cae en «Sì»: lo de arriba de «Rifiuto» no cambia al abrir el paso (en cada idioma, con o sin «Accetto», y con un aviso o un error a la vista) y lo destructivo va debajo", () => {
    /** La página hasta «Rifiuto»: si es igual, «Rifiuto» queda en el mismo lugar, sea cual sea el largo de los textos. */
    const upToDecline = (tree: VNode): string => {
      const html = toHtml(tree);
      const at = html.indexOf('id="quote-decline"');
      expect(at).toBeGreaterThan(-1);
      return html.slice(0, at);
    };
    const changesRequested = quoteView({}, { state: "changesRequested", changesRequestedAt: "2027-02-26T10:00:00+00:00" });
    // Lo que puede estar a la vista arriba de «Rifiuto» cuando lo toca: nada, o el aviso de la página, el del recuadro y
    // el error de aceptar (el controlador no los borra al abrir el paso).
    const shown: RenderOptions[] = [
      {},
      {
        pageNotice: { key: "reservation.notices.sessionCancelled", date: "2027-03-15" },
        quoteUi: { notice: { key: "reservation.quote.notices.outdated" }, error: { key: "reservation.errors.network" } },
      },
    ];
    for (const value of [quoteView(), changesRequested]) {
      for (const lang of ["it", "es", "en"] as const) {
        for (const [index, extra] of shown.entries()) {
          const label = `${lang} ${value.weeks[0]?.menu?.state} ${index}`;
          const closed = render(ready(value), { ...extra, lang });
          const open = render(ready(value), { ...extra, lang, quoteUi: { ...extra.quoteUi, declineOpen: true, declineFor: SEND_1 } });
          expect(upToDecline(open), label).toBe(upToDecline(closed));
          if (index > 0) {
            for (const id of ["reservation-notice", "quote-error"]) expect(upToDecline(open), `${label} ${id}`).toContain(`id="${id}"`);
            expect(upToDecline(open), label).toContain('class="quote__notice"');
          }
          const html = toHtml(byId(open, "quote") ?? "");
          const at = (id: string): number => html.indexOf(`id="${id}"`);
          expect(at("quote-decline"), label).toBeLessThan(at("quote-decline-question"));
          expect(at("quote-decline-question"), label).toBeLessThan(at("quote-decline-cancel"));
          expect(at("quote-decline-cancel"), label).toBeLessThan(at("quote-decline-confirm"));
        }
      }
    }
  });

  it("el error del rechazo va en el paso, junto a «Sì»; el de aceptar, arriba de los botones (también con el paso abierto)", () => {
    const network = { key: "reservation.errors.network" } as const;
    const declining = render(ready(quoteView()), { quoteUi: { declineOpen: true, declineFor: SEND_1, declineError: network } });
    const group = byId(declining, "quote-confirm");
    expect(group && textOf(byId(group, "quote-decline-error") ?? "")).toBe("Non riusciamo a collegarci. Controlla la connessione e riprova.");
    expect(byId(declining, "quote-error")).toBeNull();
    const html = toHtml(group ?? "");
    expect(html.indexOf('id="quote-decline-error"')).toBeLessThan(html.indexOf('id="quote-decline-confirm"'));
    for (const declineOpen of [false, true]) {
      const accepting = render(ready(quoteView()), { quoteUi: { declineOpen, declineFor: declineOpen ? SEND_1 : null, error: network } });
      const box = toHtml(byId(accepting, "quote") ?? "");
      expect(box.indexOf('id="quote-error"'), String(declineOpen)).toBeGreaterThan(-1);
      expect(box.indexOf('id="quote-error"'), String(declineOpen)).toBeLessThan(box.indexOf('id="quote-accept"'));
      expect(byId(accepting, "quote-decline-error")).toBeNull();
    }
  });

  it("con una respuesta en camino, los botones quedan aria-disabled (conservan el foco) y dicen «Un momento…»", () => {
    const accepting = render(ready(quoteView()), { quoteUi: { busy: "accept" } });
    expect(byId(accepting, "quote-accept")?.attrs["aria-disabled"]).toBe("true");
    expect(textOf(byId(accepting, "quote-accept") ?? "")).toBe("Un momento…");
    expect(byId(accepting, "quote-decline")?.attrs["aria-disabled"]).toBe("true");
    const declining = render(ready(quoteView()), { quoteUi: { busy: "decline", declineOpen: true } });
    expect(textOf(byId(declining, "quote-decline-confirm") ?? "")).toBe("Un momento…");
    expect(byId(declining, "quote-decline-cancel")?.attrs["aria-disabled"]).toBe("true");
  });

  it("retirado o vencido mientras contestaba: el aviso dice qué pasó con su respuesta, sin repetir el estado (en cada idioma)", () => {
    const expected: Record<Lang, Record<"withdrawn" | "expired", string>> = {
      it: {
        withdrawn: "Non abbiamo potuto registrare la tua risposta: il preventivo era già stato ritirato.",
        expired: "Non abbiamo potuto registrare la tua risposta: il tempo per accettarlo era già finito.",
      },
      es: {
        withdrawn: "No pudimos registrar tu respuesta: el presupuesto ya se había retirado.",
        expired: "No pudimos registrar tu respuesta: ya había terminado el plazo para aceptarlo.",
      },
      en: {
        withdrawn: "We couldn't record your answer: this quote had already been withdrawn.",
        expired: "We couldn't record your answer: the time to accept it had already run out.",
      },
    };
    const keys = { withdrawn: "reservation.quote.notices.closedWithdrawn", expired: "reservation.quote.notices.closedExpired" } as const;
    for (const lang of ["it", "es", "en"] as const) {
      for (const status of ["withdrawn", "expired"] as const) {
        const tree = render(ready(quoteView({ status, summary: null })), { lang, quoteUi: { notice: { key: keys[status] } } });
        const status_ = byId(tree, "quote-status");
        const notice = texts(status_ ?? tree, "quote__notice")[0] ?? "";
        const state = texts(status_ ?? tree, "quote__state")[0] ?? "";
        expect(notice, `${lang} ${status}`).toBe(expected[lang][status]);
        // La primera frase del estado (sin la etiqueta) no se repite en el aviso, ni el aviso está en el estado.
        const firstSentence = state.replace(/^\S+\s/, "").split(/(?<=\.)\s/)[0] ?? "";
        expect(firstSentence.length, `${lang} ${status}`).toBeGreaterThan(10);
        expect(notice, `${lang} ${status}`).not.toContain(firstSentence);
        expect(state, `${lang} ${status}`).not.toContain(notice);
      }
    }
  });

  it("el error de la última respuesta, junto a los botones; el aviso, en el estado (que recibe el foco)", () => {
    const failed = render(ready(quoteView()), { quoteUi: { error: { key: "reservation.errors.network" } } });
    expect(textOf(byId(failed, "quote-error") ?? "")).toBe("Non riusciamo a collegarci. Controlla la connessione e riprova.");
    const done = render(ready(quoteView({ status: "accepted", acceptedAt: "2027-02-26T10:00:00+00:00" }, { state: "confirmed", confirmedAt: "2027-02-26T10:00:00+00:00" })), {
      quoteUi: { notice: { key: "reservation.quote.notices.accepted" } },
    });
    const status = byId(done, "quote-status");
    expect(status && texts(status, "quote__notice")).toEqual(["Grazie! Hai accettato il preventivo e il menù: abbiamo avvisato Evelyn."]);
  });
});

describe("el presupuesto en español y en inglés", () => {
  it("los textos, el plazo y los importes en el idioma de la página", () => {
    const es = render(ready(quoteView()), { lang: "es" });
    expect(textOf(byId(es, "quote-title") ?? "")).toBe("Tu presupuesto");
    expect(quoteStatusText(es)).toBe(
      "Por aceptar Puedes aceptarlo hasta el sábado, 27 de febrero de 2027 a las 19:03. Hasta entonces, estas fechas quedan reservadas para ti.",
    );
    expect(texts(es, "quote__week-label")).toEqual(["Semana 1", "Semana 2"]);
    expect(texts(es, "quote__week-when")[0]).toBe("lunes, 1 de marzo de 2027 · llegada a las 10:00");
    expect(texts(es, "quote__total-value").map(plain)).toEqual(["300,00 €"]);
    expect(textOf(byId(es, "quote-accept") ?? "")).toBe("Acepto el presupuesto");
    expect(textOf(byId(es, "quote-decline") ?? "")).toBe("Rechazo");

    const en = render(ready(quoteView()), { lang: "en" });
    expect(textOf(byId(en, "quote-title") ?? "")).toBe("Your quote");
    expect(quoteStatusText(en)).toBe("To accept You can accept it until Saturday 27 February 2027 at 19:03. Until then, these dates are held for you.");
    expect(texts(en, "quote__week-price")).toEqual(["€150.00", "€150.00"]);
    expect(texts(en, "quote__total")).toEqual(["Service total €300.00"]);
    expect(textOf(byId(en, "quote-accept") ?? "")).toBe("I accept the quote");
    expect(statusText(en)).toBe("With the quote Evelyn sent you this menu with the quote on Thursday 25 February 2027. You confirm it when you accept the quote, above.");
  });

  it("lo que llega de la función va como texto también en el presupuesto (el nombre de la cocinera)", () => {
    const tree = render(ready({ ...quoteView({ status: "withdrawn" }), chefName: "<b>Eve</b>" }));
    const html = toHtml(tree);
    expect(html).not.toContain("<b>Eve</b>");
    expect(html).toContain("&lt;b&gt;Eve&lt;/b&gt;");
  });

  it("focusId: el id de lo que recibe el foco en el presupuesto", () => {
    expect(focusId({ kind: "quoteStatus" })).toBe("quote-status");
    expect(focusId({ kind: "quoteAccept" })).toBe("quote-accept");
    expect(focusId({ kind: "quoteDecline" })).toBe("quote-decline");
    expect(focusId({ kind: "quoteDeclineQuestion" })).toBe("quote-decline-question");
    expect(focusId({ kind: "quoteDeclineConfirm" })).toBe("quote-decline-confirm");
  });
});
