import { describe, expect, it } from "vitest";
import { buildMenuResponse } from "../../../supabase/functions/_shared/menu.ts";
import { i18nFor, validRequest } from "./fixtures.ts";
import {
  dishesInSeason,
  doneMenu,
  fetchMenu,
  menuMax,
  menuPanelView,
  menuState,
  menuUrl,
  reconcileMenu,
  seasonMonth,
  toggleDish,
  type MenuDish,
  type MenuPanelInput,
  type MenuState,
} from "./menu.ts";

// Las lasagne, de octubre a diciembre; el minestrone, todo el año, sin traducción al español; la
// panzanella, solo en verano.
const LASAGNE: MenuDish = {
  id: "0a1b2c3d-4e5f-4a6b-8c7d-0123456789ab",
  name: { it: "Lasagne", es: "Lasaña", en: null },
  description: { it: "Ragù e besciamella.", es: "Ragú y bechamel.", en: null },
  allergens: ["gluten", "eggs", "milk"],
  diet: null,
  seasonMonths: [10, 11, 12],
};
const MINESTRONE: MenuDish = {
  id: "1a1b2c3d-4e5f-4a6b-8c7d-0123456789ab",
  name: { it: "Minestrone", es: null, en: "Minestrone soup" },
  description: { it: "Verdure di stagione.", es: null, en: "Seasonal vegetables." },
  allergens: [],
  diet: "vegan",
  seasonMonths: null,
};
const PANZANELLA: MenuDish = {
  id: "2a1b2c3d-4e5f-4a6b-8c7d-0123456789ab",
  name: { it: "Panzanella", es: null, en: null },
  description: { it: "Pane, pomodoro e basilico.", es: null, en: null },
  allergens: ["gluten"],
  diet: "vegetarian",
  seasonMonths: [6, 7, 8],
};
const READY: MenuState = { kind: "ready", dishes: [LASAGNE, MINESTRONE, PANZANELLA] };
const NOVEMBER = 11;

const URL_OK = menuUrl("https://abc.supabase.co/");

function view(overrides: Partial<MenuPanelInput> = {}, lang: "it" | "es" | "en" = "it") {
  return menuPanelView({ state: READY, selected: [], days: 5, month: NOVEMBER, removed: [], ...overrides }, i18nFor(lang));
}

describe("catálogo: GET …/menu", () => {
  it("la URL es la de la función, en Frankfurt", () => {
    expect(URL_OK).toBe("https://abc.supabase.co/functions/v1/public-request/menu?forceFunctionRegion=eu-central-1");
  });

  it("GET simple: sin cabeceras propias (no hay preflight) ni cookies; devuelve los platos", async () => {
    let seen: { url: string; init: RequestInit } | null = null;
    const dishes = await fetchMenu(URL_OK, {
      fetch: async (url, init) => {
        seen = { url, init };
        return new Response(JSON.stringify(buildMenuResponse([LASAGNE, MINESTRONE])), { status: 200 });
      },
    });
    expect(dishes).toEqual([LASAGNE, MINESTRONE]);
    const { url, init } = seen as unknown as { url: string; init: RequestInit };
    expect(url).toBe(URL_OK);
    expect(init.method).toBe("GET");
    expect(init.headers).toBeUndefined();
    expect(init.credentials).toBe("omit");
  });

  it("503, JSON roto, otra versión, sin conexión o tiempo agotado: null (el menù lo propone Evelyn)", async () => {
    const respond = (status: number, body: string) => async () => new Response(body, { status });
    expect(await fetchMenu(URL_OK, { fetch: respond(503, '{"error":"unavailable"}') })).toBeNull();
    expect(await fetchMenu(URL_OK, { fetch: respond(200, "no es json") })).toBeNull();
    expect(await fetchMenu(URL_OK, { fetch: respond(200, '{"version":2,"dishes":[]}') })).toBeNull();
    expect(await fetchMenu(URL_OK, { fetch: async () => Promise.reject(new TypeError("Failed to fetch")) })).toBeNull();
    const hanging = (_url: string, init: RequestInit): Promise<Response> =>
      new Promise((_resolve, reject) => init.signal?.addEventListener("abort", () => reject(new Error("abort"))));
    expect(await fetchMenu(URL_OK, { fetch: hanging, timeoutMs: 10 })).toBeNull();
    expect(menuState(null)).toEqual({ kind: "error" });
    expect(menuState([])).toEqual({ kind: "ready", dishes: [] });
  });
});

describe("temporada", () => {
  it("el mes de la primera fecha elegida o, sin fecha, el de hoy (Roma)", () => {
    expect(seasonMonth("2027-07-05", "2026-11-19")).toBe(7);
    expect(seasonMonth("", "2026-11-19")).toBe(11);
  });

  it("se muestran los de todo el año y los de ese mes, en el orden del catálogo", () => {
    expect(dishesInSeason(READY, NOVEMBER)).toEqual([LASAGNE, MINESTRONE]);
    expect(dishesInSeason(READY, 7)).toEqual([MINESTRONE, PANZANELLA]);
    expect(dishesInSeason({ kind: "loading" }, 7)).toEqual([]);
    expect(view().cards.map((card) => card.name)).toEqual(["Lasagne", "Minestrone"]);
  });

  it("un elegido que sale de temporada al cambiar la fecha se quita y se avisa; los demás quedan en su orden", () => {
    const after = reconcileMenu([MINESTRONE.id, LASAGNE.id], READY, 7);
    expect(after).toEqual({ selected: [MINESTRONE.id], removed: [LASAGNE] });
    expect(view({ selected: after.selected, removed: after.removed, month: 7 }).message).toBe(
      "Lasagne non è di stagione nel mese che hai scelto e non fa più parte del tuo menù.",
    );
    // Sin nada fuera de temporada, nada que avisar; sin catálogo, nada que sacar.
    expect(reconcileMenu([MINESTRONE.id, LASAGNE.id], READY, NOVEMBER)).toEqual({ selected: [MINESTRONE.id, LASAGNE.id], removed: [] });
    expect(reconcileMenu([LASAGNE.id], { kind: "error" }, 7)).toEqual({ selected: [LASAGNE.id], removed: [] });
    const two = view({ removed: [LASAGNE, PANZANELLA] }, "es").message;
    expect(two).toBe("Lasaña, Panzanella no son de temporada en el mes que elegiste y ya no están en tu menú.");
  });
});

describe("tope: un plato por día", () => {
  it("tope de los días; con los días inválidos, el valor más cercano del rango", () => {
    expect(menuMax(5)).toBe(5);
    expect(menuMax(1)).toBe(1);
    expect(menuMax(Number.NaN)).toBe(7);
    expect(menuMax(0)).toBe(1);
    expect(menuMax(9)).toBe(7);
  });

  it("se guardan en el orden en que los tildó; al tope no se suma otro", () => {
    let selected = toggleDish([], MINESTRONE.id, true, 2);
    selected = toggleDish(selected, LASAGNE.id, true, 2);
    expect(selected).toEqual([MINESTRONE.id, LASAGNE.id]);
    expect(toggleDish(selected, PANZANELLA.id, true, 2)).toEqual([MINESTRONE.id, LASAGNE.id]);
    expect(toggleDish(selected, MINESTRONE.id, false, 2)).toEqual([LASAGNE.id]);
    expect(toggleDish(selected, LASAGNE.id, true, 2)).toEqual(selected);
  });

  it("al llegar al tope, las demás casillas se deshabilitan (las marcadas no)", () => {
    const at = view({ days: 1, selected: [LASAGNE.id] });
    expect(at.cards.map((card) => [card.name, card.checked, card.disabled])).toEqual([
      ["Lasagne", true, false],
      ["Minestrone", false, true],
    ]);
    expect(at.count).toBe("Scelti: 1 di 1");
    expect(at.overLimit).toBe(false);
    expect(view({ selected: [LASAGNE.id] }).cards.every((card) => !card.disabled)).toBe(true);
  });

  it("si bajan los días por debajo de lo elegido, el contador queda en error", () => {
    const over = view({ days: 1, selected: [LASAGNE.id, MINESTRONE.id] });
    expect(over.overLimit).toBe(true);
    expect(over.count).toBe("Scelti: 2 di 1: togline 1 o aggiungi giorni.");
    // Las marcadas se pueden desmarcar.
    expect(over.cards.every((card) => card.checked && !card.disabled)).toBe(true);
  });
});

describe("panel", () => {
  it("con platos: la ayuda con los días, el contador y cada tarjeta con nombre, descripción, alérgenos y dieta", () => {
    const panel = view();
    expect(panel.hint).toBe("Scegli fino a 5 piatti, uno per giorno. È facoltativo: il resto lo propone Evelyn.");
    expect(panel.count).toBe("Scelti: 0 di 5");
    expect(panel.message).toBe("");
    expect(panel.cards).toEqual([
      {
        id: LASAGNE.id,
        name: "Lasagne",
        description: "Ragù e besciamella.",
        allergens: "Allergeni: glutine, uova, latte e derivati",
        diet: null,
        checked: false,
        disabled: false,
      },
      {
        id: MINESTRONE.id,
        name: "Minestrone",
        description: "Verdure di stagione.",
        allergens: "Nessuno dei 14 allergeni principali",
        diet: "Vegano",
        checked: false,
        disabled: false,
      },
    ]);
    expect(view({ days: 1 }).hint).toBe("Puoi scegliere un piatto. È facoltativo: se non lo scegli, lo propone Evelyn.");
  });

  it("nombres y descripciones en el idioma de la página, con respaldo al italiano", () => {
    const es = view({}, "es").cards;
    expect(es.map((card) => [card.name, card.description])).toEqual([
      ["Lasaña", "Ragú y bechamel."],
      ["Minestrone", "Verdure di stagione."],
    ]);
    expect(es[0]?.allergens).toBe("Alérgenos: gluten, huevos, leche y lácteos");
    const en = view({ month: 7 }, "en").cards;
    expect(en.map((card) => [card.name, card.diet])).toEqual([
      ["Minestrone soup", "Vegan"],
      ["Panzanella", "Vegetarian"],
    ]);
    expect(view({}, "en").count).toBe("Chosen: 0 of 5");
  });

  it("sin platos, sin platos de temporada, cargando o si la consulta falló: sin tarjetas ni contador, y el porqué", () => {
    const cases: Array<[MenuState, number, string]> = [
      [{ kind: "ready", dishes: [] }, NOVEMBER, "Il menù te lo propone Evelyn: se vuoi, scrivi nelle note i piatti che ti piacciono."],
      [{ kind: "ready", dishes: [PANZANELLA] }, NOVEMBER, "Il menù te lo propone Evelyn: se vuoi, scrivi nelle note i piatti che ti piacciono."],
      [{ kind: "error" }, NOVEMBER, "Non riusciamo a mostrare i piatti: il menù te lo propone Evelyn. Puoi inviare la richiesta lo stesso."],
      [{ kind: "loading" }, NOVEMBER, "Sto caricando i piatti…"],
    ];
    for (const [state, month, message] of cases) {
      const panel = view({ state, month });
      expect(panel, state.kind).toMatchObject({ hint: null, count: null, overLimit: false, cards: [], message });
    }
  });
});

describe("pantalla de gracias", () => {
  const choice = (dish: MenuDish) => ({ id: dish.id, name: dish.name });

  it("los platos que guardó el servidor (el menu del 201), aunque sean menos que los elegidos", () => {
    const data = validRequest({ menu: [LASAGNE.id, MINESTRONE.id] });
    expect(doneMenu(data, [choice(MINESTRONE)], READY)).toEqual([choice(MINESTRONE)]);
    expect(doneMenu(data, [], READY)).toEqual([]);
  });

  it("si el 201 no lo trajo, los elegidos con los nombres del catálogo; sin datos del pedido, ninguno", () => {
    const data = validRequest({ menu: [MINESTRONE.id, LASAGNE.id] });
    expect(doneMenu(data, null, READY)).toEqual([choice(MINESTRONE), choice(LASAGNE)]);
    expect(doneMenu(data, null, { kind: "error" })).toEqual([]);
    expect(doneMenu(null, [choice(LASAGNE)], READY)).toEqual([]);
  });
});
