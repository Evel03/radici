// Datos de prueba de la página /prenotazione/: una reserva de dos semanas, la primera con el menú enviado.
import {
  CLIENT_LINK_VERSION,
  type ClientLinkMenu,
  type ClientLinkView,
  type ClientLinkWeek,
  type MenuContent,
} from "../../../supabase/functions/_shared/client_link.ts";
import { recipePhotoUrls } from "../../../supabase/functions/_shared/menu.ts";

export const SUPABASE_URL = "https://abcdefgh.supabase.co";
export const TOKEN = "B_wWbkraJZQT6glUNfUKI2uxzam1sC16p8ZBTilzOWg";
export const SEND_1 = "5e0d0000-0000-4000-8000-000000000001";
export const SEND_NEW = "5e0d0000-0000-4000-8000-000000000002";
export const SEND_2 = "5e0d0000-0000-4000-8000-000000000003";
/** Las sesiones de la reserva: la identidad de cada semana en la página. */
export const SESSION_1 = "5e550000-0000-4000-8000-000000000001";
export const SESSION_2 = "5e550000-0000-4000-8000-000000000002";
export const SESSION_3 = "5e550000-0000-4000-8000-000000000003";

/** La sesión de la semana k de los tests (5e55…000k). */
export function session(k: number): string {
  return `5e550000-0000-4000-8000-${String(k).padStart(12, "0")}`;
}
const CHEF_ID = "cef00000-0000-4000-8000-000000000001";
const RECIPE_ID = "0a1b2c3d-4e5f-4a6b-8c7d-0123456789ab";
const PHOTO_ID = "9f8e7d6c-5b4a-4c3d-8e2f-1a0b9c8d7e6f";

export const PHOTO = recipePhotoUrls(SUPABASE_URL, CHEF_ID, RECIPE_ID, PHOTO_ID);

/** Lo que mandó Evelyn, en italiano: dos platos (uno con foto), la lista y una nota con saltos de línea. */
export function content(overrides: Partial<MenuContent> = {}): MenuContent {
  return {
    locale: "it",
    dishes: [
      {
        name: "Lasagne al ragù",
        description: "Ragù di manzo e besciamella.",
        allergens: ["gluten", "eggs", "milk"],
        diet: null,
        portions: 6,
        photo: PHOTO,
      },
      { name: "Minestrone", description: null, allergens: [], diet: "vegan", portions: 1, photo: null },
    ],
    items: [
      { name: "Sale", section: "pantry", quantity: null, unit: null },
      { name: "Pomodori", section: "produce", quantity: 1250, unit: "g" },
      { name: "Latte", section: "dairy_eggs", quantity: 1500, unit: "ml" },
      { name: "Zucchine", section: "produce", quantity: 250, unit: "g" },
      { name: "Uova", section: "dairy_eggs", quantity: 3, unit: "pcs" },
      { name: "Olio", section: "pantry", quantity: null, unit: null },
    ],
    note: "Ciao Anna!\nArrivo alle 10.",
    ...overrides,
  };
}

export function menu(overrides: Partial<ClientLinkMenu> = {}): ClientLinkMenu {
  return {
    sendId: SEND_1,
    sentAt: "2027-02-25T18:03:00.123456+00:00",
    state: "pending",
    confirmedAt: null,
    changesRequestedAt: null,
    content: content(),
    ...overrides,
  };
}

export function week(overrides: Partial<ClientLinkWeek> = {}): ClientLinkWeek {
  return { sessionId: SESSION_1, week: 1, weeks: 2, date: "2027-03-01", start: "10:00", done: false, menu: menu(), ...overrides };
}

/** La reserva: la semana 1 con el menú por confirmar, la 2 sin menú todavía. */
export function view(overrides: Partial<ClientLinkView> = {}): ClientLinkView {
  return {
    version: CLIENT_LINK_VERSION,
    locale: "it",
    chefName: "Evelyn",
    clientFirstName: "Anna",
    weeks: [week(), week({ sessionId: SESSION_2, week: 2, date: "2027-03-08", menu: null })],
    ...overrides,
  };
}
