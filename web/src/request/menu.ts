// Pestaña «Menù» del formulario: los platos de Evelyn, para elegir hasta uno por día (opcional; decisión del
// 19/11/2026). Pura: la página (richiesta.ts) solo pinta lo que devuelve.
// - Los platos llegan de GET <función public-request>/menu (contrato en supabase/functions/_shared/menu.ts).
//   Es una petición simple (GET sin cabeceras propias, sin preflight) y el servidor la deja cachear 60 s.
//   Sin platos, o si la consulta falla, el panel dice que el menù lo propone Evelyn y el pedido sale igual.
// - Temporada: los de todo el año y los del mes de la primera fecha elegida (en Roma) o, sin fecha, del mes
//   de hoy. Si al cambiar la fecha un plato elegido sale de temporada, se quita y se avisa.
// - Tope: un plato por día. Al llegar, las demás casillas se deshabilitan; si bajan los días por debajo de
//   lo elegido, el contador queda en error y la validación (la del servidor: menu "tooMany") frena el envío.
// Los nombres y descripciones van en el idioma de la página, con respaldo al italiano.
import {
  MENU_PATH,
  dishInSeason,
  localizedText,
  parseMenuResponse,
  type MenuChoice,
  type MenuDish,
} from "../../../supabase/functions/_shared/menu.ts";
import { LIMITS } from "../engine.ts";
import type { I18n } from "../i18n/core.ts";
import type { RequestData } from "./model.ts";
import { FUNCTION_REGION, PUBLIC_REQUEST_PATH } from "./submit.ts";

export type { MenuChoice, MenuDish } from "../../../supabase/functions/_shared/menu.ts";

/** Más que esto y el panel dice que el menù lo propone Evelyn: el formulario no espera al catálogo. */
export const MENU_TIMEOUT_MS = 8_000;

export function menuUrl(supabaseUrl: string): string {
  const base = supabaseUrl.replace(/\/+$/, "");
  return `${base}${PUBLIC_REQUEST_PATH}${MENU_PATH}?forceFunctionRegion=${FUNCTION_REGION}`;
}

export interface MenuFetchOptions {
  /** Para los tests; en el navegador, window.fetch. */
  fetch?: (input: string, init: RequestInit) => Promise<Response>;
  timeoutMs?: number;
}

/** Los platos publicados, o null si no hubo una respuesta útil (sin conexión, tiempo agotado, error, otra forma). */
export async function fetchMenu(url: string, opts: MenuFetchOptions = {}): Promise<MenuDish[] | null> {
  // Llamada envuelta: algunos navegadores fallan si fetch se invoca sin su `this` (window).
  const fetchFn = opts.fetch ?? ((input: string, init: RequestInit) => fetch(input, init));
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), opts.timeoutMs ?? MENU_TIMEOUT_MS);
  try {
    const response = await fetchFn(url, { method: "GET", credentials: "omit", signal: controller.signal });
    if (!response.ok) return null;
    return parseMenuResponse(JSON.parse(await response.text()) as unknown)?.dishes ?? null;
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
  }
}

/** Estado del catálogo en la página. */
export type MenuState =
  | { kind: "loading" }
  /** La respuesta llegó (puede no traer platos). */
  | { kind: "ready"; dishes: readonly MenuDish[] }
  /** Sin respuesta útil: el menù lo propone Evelyn. */
  | { kind: "error" };

export function menuState(dishes: readonly MenuDish[] | null): MenuState {
  return dishes ? { kind: "ready", dishes } : { kind: "error" };
}

/** Mes (1 a 12) de la temporada: el de la primera fecha elegida o, sin fecha, el de hoy. Fechas de Roma, "AAAA-MM-DD". */
export function seasonMonth(preferredDate: string, today: string): number {
  return Number((preferredDate || today).slice(5, 7));
}

/** Los platos que se pueden elegir ese mes (de todo el año o de temporada), en el orden del catálogo. */
export function dishesInSeason(state: MenuState, month: number): MenuDish[] {
  return state.kind === "ready" ? state.dishes.filter((dish) => dishInSeason(dish, month)) : [];
}

/**
 * Tope de platos: uno por día. Con los días inválidos (el campo vacío mientras se escribe, o fuera de rango)
 * se toma el valor más cercano del rango: el error de los días lo marca su campo.
 */
export function menuMax(days: number): number {
  if (!Number.isFinite(days)) return LIMITS.maxDays;
  return Math.min(LIMITS.maxDays, Math.max(1, Math.trunc(days)));
}

/**
 * Marcar o desmarcar un plato. Se guarda en el orden en que los tildó (así llegan a Evelyn); al tope no se
 * suma otro (su casilla está deshabilitada; esto cubre un clic que llegue igual).
 */
export function toggleDish(selected: readonly string[], id: string, checked: boolean, max: number): string[] {
  if (!checked) return selected.filter((item) => item !== id);
  if (selected.includes(id) || selected.length >= max) return [...selected];
  return [...selected, id];
}

/**
 * Después de un cambio de fecha (o cuando llega el catálogo): saca los elegidos que no se pueden elegir ese
 * mes (fuera de temporada, o que ya no están) y dice cuáles, para avisar. Sin catálogo no hay qué sacar.
 */
export function reconcileMenu(selected: readonly string[], state: MenuState, month: number): { selected: string[]; removed: MenuDish[] } {
  if (state.kind !== "ready") return { selected: [...selected], removed: [] };
  const available = new Set(dishesInSeason(state, month).map((dish) => dish.id));
  const removed = state.dishes.filter((dish) => selected.includes(dish.id) && !available.has(dish.id));
  return { selected: selected.filter((id) => available.has(id)), removed };
}

export interface DishCard {
  id: string;
  name: string;
  description: string;
  /** «Allergeni: glutine, latte e derivati» o «Nessuno dei 14 allergeni principali». */
  allergens: string;
  /** «Vegetariano», «Vegano» o null. */
  diet: string | null;
  checked: boolean;
  /** Al tope, las que no están marcadas. */
  disabled: boolean;
}

export interface MenuPanelView {
  /** «Scegli fino a 5 piatti…»: solo si hay platos para elegir. */
  hint: string | null;
  /** Lo que dice el renglón de estado: el aviso de los que salieron de temporada, cargando, error o sin platos. */
  message: string;
  /** «Scelti: 2 di 5»; null si no hay platos para elegir. */
  count: string | null;
  /** Más elegidos que días: el contador queda en error. */
  overLimit: boolean;
  cards: DishCard[];
}

export interface MenuPanelInput {
  state: MenuState;
  /** Los elegidos, en el orden en que los tildó. */
  selected: readonly string[];
  days: number;
  /** Mes de la temporada (seasonMonth). */
  month: number;
  /** Los que se quitaron por la temporada en el último cambio de fecha (para avisar); [] si ninguno. */
  removed: readonly MenuDish[];
}

/** Lo que muestra el panel «Menù». */
export function menuPanelView(input: MenuPanelInput, i18n: I18n): MenuPanelView {
  const { t, lang } = i18n;
  const dishes = dishesInSeason(input.state, input.month);
  const max = menuMax(input.days);
  const chosen = input.selected.length;
  const messages: string[] = [];
  if (input.removed.length > 0) {
    const names = input.removed.map((dish) => localizedText(dish.name, lang)).join(", ");
    messages.push(t(input.removed.length === 1 ? "request.menu.removedOne" : "request.menu.removedOther", { dishes: names }));
  }
  if (input.state.kind === "loading") messages.push(t("request.menu.loading"));
  else if (input.state.kind === "error") messages.push(t("request.menu.error"));
  else if (dishes.length === 0) messages.push(t("request.menu.empty"));

  const overLimit = chosen > max;
  const cards = dishes.map((dish): DishCard => {
    const checked = input.selected.includes(dish.id);
    return {
      id: dish.id,
      name: localizedText(dish.name, lang),
      description: localizedText(dish.description, lang),
      allergens:
        dish.allergens.length === 0
          ? t("request.menu.allergensNone")
          : t("request.menu.allergens", { list: dish.allergens.map((allergen) => t(`allergens.${allergen}`)).join(", ") }),
      diet: dish.diet ? t(`diets.${dish.diet}`) : null,
      checked,
      disabled: !checked && chosen >= max,
    };
  });
  const some = cards.length > 0;
  return {
    hint: some ? (max === 1 ? t("request.menu.hintOne") : t("request.menu.hint", { days: max })) : null,
    message: messages.join(" "),
    count: some
      ? overLimit
        ? t("request.menu.countOver", { chosen, max, extra: chosen - max })
        : t("request.menu.count", { chosen, max })
      : null,
    overLimit,
    cards,
  };
}

/**
 * Los platos que muestra la pantalla de gracias: los que guardó el servidor (el `menu` del 201, con los
 * nombres de las recetas) o, si no vino (o con otra forma), los elegidos con los nombres del catálogo de la
 * página. Sin los datos del pedido (no se sabe qué guardó el servidor), ninguno.
 */
export function doneMenu(data: RequestData | null, fromServer: readonly MenuChoice[] | null, state: MenuState): MenuChoice[] {
  if (!data) return [];
  if (fromServer) return [...fromServer];
  if (state.kind !== "ready") return [];
  return data.menu.flatMap((id) => state.dishes.filter((dish) => dish.id === id).map((dish) => ({ id: dish.id, name: dish.name })));
}
