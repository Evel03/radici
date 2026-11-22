// El mensaje con el menú de una semana para la clienta (SPEC 5.8, contrato chef-api.md §13): el email
// (asunto, HTML y texto) y el texto del WhatsApp, en el idioma de la clienta (it, es o en). Lo usa la
// función chef para la vista previa (sin el link: en su lugar va un texto de reemplazo) y para el envío.
//
// Sale todo de la foto del envío (menu_snapshot.ts), así lo que Evelyn ve en la vista previa es lo que
// le llega a la clienta: la semana (k de N), el día y la llegada; en la semana 1, todas las fechas de
// la reserva; los platos con su descripción, sus porciones, su dieta y sus alérgenos (los 14 del Reg.
// UE 1169/2011, con su nombre); la lista de compras por sección del súper, con cantidades legibles, y
// lo que va q.b. aparte («para tener en casa»); la nota de Evelyn; el link para ver el menú entero y
// confirmarlo (o pedir cambios) y cómo responder.
//
// Nunca lleva la dirección, el contacto, las alergias de la clienta, precios ni nada de pagos: la
// entrada no los tiene. Del nombre de la clienta, solo el de pila si parece un nombre (safeFirstName):
// el email o el teléfono pueden venir del formulario, sin verificar.
// HTML con el diseño compartido de emails.ts (render), con todo el texto escapado; sin imágenes remotas
// (las fotos de los platos quedan para la página del link). El texto plano y el WhatsApp se arman acá.
// Solo sintaxis borrable (corre en Node, Deno y Vite sin compilar) e imports con extensión .ts.
import {
  escapeHtml,
  formatDateLong,
  formatDayMonth,
  render as renderEmailDocument,
  safeFirstName,
  type Block,
  type EmailDocument,
  type Row,
} from "./emails.ts";
import {
  SHOPPING_SECTIONS,
  type IngredientUnit,
  type MenuSnapshot,
  type MenuSnapshotDish,
  type MenuSnapshotItem,
  type ShoppingSection,
} from "./menu_snapshot.ts";
import type { Allergen, Diet, Locale } from "./public_request.ts";

export interface MenuMessageInput {
  /** Nombre de la marca (brandFromMailFrom de MAIL_FROM). */
  brand: string;
  /** Nombre de la cocinera (chefs.display_name). */
  chefName: string;
  /** El nombre del contacto tal cual: del mensaje sale solo el nombre de pila, si parece un nombre. */
  clientName: string | null;
  snapshot: MenuSnapshot;
  /** El link de la clienta; null en la vista previa: va el texto de reemplazo (linkPlaceholder). */
  link: string | null;
}

export interface RenderedMenuMessage {
  subject: string;
  html: string;
  /** El texto plano del email: lo que la app muestra en la vista previa del email. */
  text: string;
  /** Texto plano con *negrita* y _cursiva_ de WhatsApp. Lo abre la app desde el teléfono de Evelyn. */
  whatsapp: string;
}

// ---------------------------------------------------------------------------
// Textos por idioma (el mismo vocabulario que la web y la app)
// ---------------------------------------------------------------------------

interface MenuMessages {
  greeting: (first: string) => string;
  /** day: la fecha corta ("30 nov"). */
  subject: (brand: string, day: string, week: number, weeks: number) => string;
  preheader: (chef: string, day: string, start: string) => string;
  /** day: la fecha larga ("lunedì 30 novembre 2026"). */
  intro: (chef: string, day: string, start: string, week: number, weeks: number) => string;
  whenTitle: string;
  weekLabel: string;
  weekValue: (week: number, weeks: number) => string;
  dayLabel: string;
  arrivalLabel: string;
  /** Las fechas de todas las semanas de la reserva (en el mensaje de la semana 1). */
  allDatesLabel: string;
  menuTitle: string;
  portions: (n: number) => string;
  allergens: (list: string) => string;
  /** Como la web (menu.allergensNone). */
  allergensNone: string;
  /** Los nombres de la web (allergens.*). */
  allergenNames: Readonly<Record<Allergen, string>>;
  diets: Readonly<Record<Diet, string>>;
  shoppingTitle: string;
  shoppingIntro: (chef: string) => string;
  /** Las secciones de la app (shoppingSection*), para quien lee: la clienta. */
  sections: Readonly<Record<ShoppingSection, string>>;
  /** Lo que va q.b.: no hay que comprar una cantidad, solo tenerlo. */
  atHome: string;
  /** Piezas: n ya formateado, count para el plural. */
  pieces: (n: string, count: number) => string;
  noteTitle: (chef: string) => string;
  confirm: string;
  button: string;
  /** En la vista previa, donde va el link (que se crea recién al enviar). */
  linkPlaceholder: string;
  replyEmail: string;
  replyWhatsapp: string;
  /** El eslogan de la marca, el mismo de la web (common.slogan) y de la confirmación del pedido. */
  slogan: string;
  footer: (brand: string) => string;
  decimal: string;
  thousands: string;
}

const MESSAGES: Readonly<Record<Locale, MenuMessages>> = {
  it: {
    greeting: (first) => (first ? `Ciao ${first}!` : "Ciao!"),
    subject: (brand, day, week, weeks) =>
      weeks > 1 ? `${brand}: il menù della settimana ${week} di ${weeks} (${day})` : `${brand}: il tuo menù del ${day}`,
    preheader: (chef, day, start) => `${chef} arriva il ${day} alle ${start}: guarda il menù e confermalo.`,
    intro: (chef, day, start, week, weeks) =>
      weeks > 1
        ? `${chef} ha preparato il menù della settimana ${week} di ${weeks}: arriva da te ${day} alle ${start}.`
        : `${chef} ha preparato il tuo menù: arriva da te ${day} alle ${start}.`,
    whenTitle: "Quando",
    weekLabel: "Settimana",
    weekValue: (week, weeks) => `${week} di ${weeks}`,
    dayLabel: "Giorno",
    arrivalLabel: "Arrivo",
    allDatesLabel: "Tutte le date",
    menuTitle: "Il menù",
    portions: (n) => (n === 1 ? "1 porzione" : `${n} porzioni`),
    allergens: (list) => `Allergeni: ${list}`,
    allergensNone: "Nessuno dei 14 allergeni principali",
    allergenNames: {
      gluten: "glutine",
      crustaceans: "crostacei",
      eggs: "uova",
      fish: "pesce",
      peanuts: "arachidi",
      soy: "soia",
      milk: "latte e derivati",
      nuts: "frutta a guscio",
      celery: "sedano",
      mustard: "senape",
      sesame: "sesamo",
      sulphites: "solfiti",
      lupin: "lupini",
      molluscs: "molluschi",
    },
    diets: { vegetarian: "Vegetariano", vegan: "Vegano" },
    shoppingTitle: "La spesa",
    shoppingIntro: (chef) => `La spesa la fai tu: tieni tutto pronto per quando arriva ${chef}.`,
    sections: {
      produce: "Frutta e verdura",
      meat_fish: "Carne e pesce",
      dairy_eggs: "Latticini e uova",
      bakery: "Panetteria",
      pantry: "Dispensa",
      frozen: "Surgelati",
      other: "Altro",
    },
    atHome: "Da avere in casa",
    pieces: (n) => `${n} pz`,
    noteTitle: (chef) => `Una nota di ${chef}`,
    confirm:
      "Apri il tuo link per vedere il menù completo, con le foto dei piatti, e confermarlo. Se vuoi cambiare qualcosa, puoi chiederlo da lì.",
    button: "Vedi e conferma il menù",
    linkPlaceholder: "[link personale per confermare]",
    replyEmail: "Hai domande? Rispondi a questa email.",
    replyWhatsapp: "Hai domande? Rispondi a questo messaggio.",
    slogan: "Cucina autentica, a casa tua.",
    footer: (brand) => `Ricevi questa email per la tua prenotazione con ${brand}.`,
    decimal: ",",
    thousands: ".",
  },
  es: {
    greeting: (first) => (first ? `¡Hola, ${first}!` : "¡Hola!"),
    subject: (brand, day, week, weeks) =>
      weeks > 1 ? `${brand}: el menú de la semana ${week} de ${weeks} (${day})` : `${brand}: tu menú del ${day}`,
    preheader: (chef, day, start) => `${chef} llega el ${day} a las ${start}: mira el menú y confírmalo.`,
    intro: (chef, day, start, week, weeks) =>
      weeks > 1
        ? `${chef} ha preparado el menú de la semana ${week} de ${weeks}: llega a tu casa el ${day} a las ${start}.`
        : `${chef} ha preparado tu menú: llega a tu casa el ${day} a las ${start}.`,
    whenTitle: "Cuándo",
    weekLabel: "Semana",
    weekValue: (week, weeks) => `${week} de ${weeks}`,
    dayLabel: "Día",
    arrivalLabel: "Llegada",
    allDatesLabel: "Todas las fechas",
    menuTitle: "El menú",
    portions: (n) => (n === 1 ? "1 porción" : `${n} porciones`),
    allergens: (list) => `Alérgenos: ${list}`,
    allergensNone: "Ninguno de los 14 alérgenos principales",
    allergenNames: {
      gluten: "gluten",
      crustaceans: "crustáceos",
      eggs: "huevos",
      fish: "pescado",
      peanuts: "cacahuetes (maní)",
      soy: "soja",
      milk: "leche y lácteos",
      nuts: "frutos de cáscara",
      celery: "apio",
      mustard: "mostaza",
      sesame: "sésamo",
      sulphites: "sulfitos",
      lupin: "altramuces",
      molluscs: "moluscos",
    },
    diets: { vegetarian: "Vegetariano", vegan: "Vegano" },
    shoppingTitle: "La compra",
    shoppingIntro: (chef) => `La compra la haces tú: tenlo todo listo para cuando llegue ${chef}.`,
    sections: {
      produce: "Fruta y verdura",
      meat_fish: "Carne y pescado",
      dairy_eggs: "Lácteos y huevos",
      bakery: "Panadería",
      pantry: "Despensa",
      frozen: "Congelados",
      other: "Otros",
    },
    atHome: "Para tener en casa",
    pieces: (n, count) => (count === 1 ? `${n} ud.` : `${n} uds.`),
    noteTitle: (chef) => `Una nota de ${chef}`,
    confirm:
      "Abre tu enlace para ver el menú completo, con las fotos de los platos, y confirmarlo. Si quieres cambiar algo, puedes pedirlo desde ahí.",
    button: "Ver y confirmar el menú",
    linkPlaceholder: "[enlace personal para confirmar]",
    replyEmail: "¿Tienes dudas? Responde a este email.",
    replyWhatsapp: "¿Tienes dudas? Responde a este mensaje.",
    slogan: "Cocina auténtica, en tu casa.",
    footer: (brand) => `Recibes este email por tu reserva con ${brand}.`,
    decimal: ",",
    thousands: ".",
  },
  en: {
    greeting: (first) => (first ? `Hi ${first}!` : "Hi!"),
    subject: (brand, day, week, weeks) =>
      weeks > 1 ? `${brand}: your menu for week ${week} of ${weeks} (${day})` : `${brand}: your menu for ${day}`,
    preheader: (chef, day, start) => `${chef} arrives on ${day} at ${start}: take a look at the menu and confirm it.`,
    intro: (chef, day, start, week, weeks) =>
      weeks > 1
        ? `${chef} has prepared the menu for week ${week} of ${weeks} and will arrive at your home on ${day} at ${start}.`
        : `${chef} has prepared your menu and will arrive at your home on ${day} at ${start}.`,
    whenTitle: "When",
    weekLabel: "Week",
    weekValue: (week, weeks) => `${week} of ${weeks}`,
    dayLabel: "Day",
    arrivalLabel: "Arrival",
    allDatesLabel: "All dates",
    menuTitle: "The menu",
    portions: (n) => (n === 1 ? "1 portion" : `${n} portions`),
    allergens: (list) => `Allergens: ${list}`,
    allergensNone: "None of the 14 major allergens",
    allergenNames: {
      gluten: "gluten",
      crustaceans: "crustaceans",
      eggs: "eggs",
      fish: "fish",
      peanuts: "peanuts",
      soy: "soya",
      milk: "milk and dairy",
      nuts: "tree nuts",
      celery: "celery",
      mustard: "mustard",
      sesame: "sesame",
      sulphites: "sulphites",
      lupin: "lupin",
      molluscs: "molluscs",
    },
    diets: { vegetarian: "Vegetarian", vegan: "Vegan" },
    shoppingTitle: "Shopping",
    shoppingIntro: (chef) => `You do the shopping: please have everything ready for when ${chef} arrives.`,
    sections: {
      produce: "Fruit and veg",
      meat_fish: "Meat and fish",
      dairy_eggs: "Dairy and eggs",
      bakery: "Bakery",
      pantry: "Pantry",
      frozen: "Frozen",
      other: "Other",
    },
    atHome: "To have at home",
    pieces: (n, count) => (count === 1 ? `${n} pc` : `${n} pcs`),
    noteTitle: (chef) => `A note from ${chef}`,
    confirm:
      "Open your link to see the full menu, with photos of the dishes, and confirm it. If you'd like to change anything, you can ask from there.",
    button: "See and confirm the menu",
    linkPlaceholder: "[personal link to confirm]",
    replyEmail: "Any questions? Just reply to this email.",
    replyWhatsapp: "Any questions? Just reply to this message.",
    slogan: "Authentic cooking, in your home.",
    footer: (brand) => `You're receiving this email about your booking with ${brand}.`,
    decimal: ".",
    thousands: ",",
  },
};

/** El texto de reemplazo del link en la vista previa, en ese idioma. */
export function linkPlaceholder(locale: Locale): string {
  return MESSAGES[locale].linkPlaceholder;
}

// ---------------------------------------------------------------------------
// Formatos (puros, también para tests)
// ---------------------------------------------------------------------------

function groupThousands(value: number, separator: string): string {
  return String(value).replace(/\B(?=(\d{3})+(?!\d))/g, separator);
}

/**
 * Cantidad de la lista, legible y con aritmética entera: "250 g", "1,25 kg" (it, es) o "1.25 kg" (en);
 * "750 ml", "1,5 l"; "3 pz" / "3 uds." / "3 pcs". Desde 1000 g o 1000 ml pasa a kg o l, redondeado a
 * la centésima (10 g o 10 ml) y sin ceros de más ("1 kg", "1,5 kg").
 */
export function formatQuantity(quantity: number, unit: IngredientUnit, locale: Locale): string {
  const messages = MESSAGES[locale];
  if (unit === "pcs") return messages.pieces(groupThousands(quantity, messages.thousands), quantity);
  if (quantity < 1000) return `${quantity} ${unit}`;
  const hundredths = Math.floor((quantity + 5) / 10);
  const whole = Math.floor(hundredths / 100);
  const rest = hundredths % 100;
  const decimals = rest === 0 ? "" : rest % 10 === 0 ? String(rest / 10) : String(rest).padStart(2, "0");
  const big = unit === "g" ? "kg" : "l";
  return `${groupThousands(whole, messages.thousands)}${decimals ? `${messages.decimal}${decimals}` : ""} ${big}`;
}

/** Un renglón de la lista como se lee: "Zucchine: 1,25 kg"; lo que va q.b., solo el nombre. */
export interface ShoppingLine {
  name: string;
  quantity: string | null;
}

export interface ShoppingGroup {
  title: string;
  lines: ShoppingLine[];
}

/**
 * La lista agrupada por sección del súper, en el orden del enum (el del recorrido), y al final lo que va
 * q.b. («para tener en casa»), también por sección. Dentro de cada grupo, el orden en que la dejó Evelyn.
 * Las secciones sin renglones no salen.
 */
export function shoppingGroups(items: readonly MenuSnapshotItem[], locale: Locale): ShoppingGroup[] {
  const messages = MESSAGES[locale];
  const groups: ShoppingGroup[] = [];
  for (const section of SHOPPING_SECTIONS) {
    const lines: ShoppingLine[] = [];
    for (const item of items) {
      if (item.section === section && item.quantity !== null && item.unit !== null) {
        lines.push({ name: item.name, quantity: formatQuantity(item.quantity, item.unit, locale) });
      }
    }
    if (lines.length > 0) groups.push({ title: messages.sections[section], lines });
  }
  const atHome: ShoppingLine[] = [];
  for (const section of SHOPPING_SECTIONS) {
    for (const item of items) {
      if (item.section === section && item.quantity === null) atHome.push({ name: item.name, quantity: null });
    }
  }
  if (atHome.length > 0) groups.push({ title: messages.atHome, lines: atHome });
  return groups;
}

function lineText(line: ShoppingLine): string {
  return line.quantity === null ? line.name : `${line.name}: ${line.quantity}`;
}

/** Un plato como se lee: nombre, descripción, porciones y dieta, y la línea de los alérgenos. */
interface DishText {
  name: string;
  description: string | null;
  details: string;
  allergens: string;
}

function dishText(dish: MenuSnapshotDish, messages: MenuMessages): DishText {
  const details = [messages.portions(dish.portions), ...(dish.diet ? [messages.diets[dish.diet]] : [])].join(" · ");
  const allergens =
    dish.allergens.length > 0
      ? messages.allergens(dish.allergens.map((allergen) => messages.allergenNames[allergen]).join(", "))
      : messages.allergensNone;
  return { name: dish.name, description: dish.description, details, allergens };
}

/**
 * Las fechas de todas las semanas de la reserva, cortas ("30 nov · 7 dic"), solo en el mensaje de la
 * semana 1 de una reserva de más de una semana. Con la hora de cada una si alguna llega a otra hora.
 */
function reservationDates(snapshot: MenuSnapshot, locale: Locale): string[] | null {
  const first = snapshot.weeks[0];
  if (snapshot.session.week !== 1 || snapshot.weeks.length < 2 || !first) return null;
  const year = Number(first.date.slice(0, 4));
  const sameTime = snapshot.weeks.every((week) => week.start === snapshot.session.start);
  return snapshot.weeks.map((week) => `${formatDayMonth(week.date, locale, year)}${sameTime ? "" : ` ${week.start}`}`);
}

/** Las líneas de la nota, sin las vacías (en el HTML, un párrafo por línea). */
function noteLines(note: string | null): string[] {
  return note === null ? [] : note.split("\n").map((line) => line.trim()).filter((line) => line !== "");
}

// ---------------------------------------------------------------------------
// El mensaje
// ---------------------------------------------------------------------------

/** Lo común a los tres formatos, ya en el idioma de la clienta. */
interface MessageParts {
  messages: MenuMessages;
  chef: string;
  greeting: string;
  intro: string;
  when: Row[];
  dates: string[] | null;
  dishes: DishText[];
  shopping: ShoppingGroup[];
  note: string[];
  link: string | null;
}

function messageParts(input: MenuMessageInput): MessageParts {
  const { snapshot } = input;
  const locale = snapshot.locale;
  const messages = MESSAGES[locale];
  const { session } = snapshot;
  const chef = input.chefName;
  const dayLong = formatDateLong(session.date, locale);
  const dates = reservationDates(snapshot, locale);
  const when: Row[] = [];
  if (session.weeks > 1) when.push({ label: messages.weekLabel, value: messages.weekValue(session.week, session.weeks) });
  when.push({ label: messages.dayLabel, value: dayLong }, { label: messages.arrivalLabel, value: session.start });
  if (dates) {
    // Como en la confirmación del pedido: espacios duros dentro de cada fecha y antes del «·», así en el
    // teléfono el renglón se corta después de un «·» y nunca en medio de una fecha.
    when.push({
      label: messages.allDatesLabel,
      value: dates.join(" · "),
      valueHtml: dates.map((date) => escapeHtml(date).replace(/ /g, "&nbsp;")).join("&nbsp;· "),
    });
  }
  return {
    messages,
    chef,
    greeting: messages.greeting(safeFirstName(input.clientName ?? "")),
    intro: messages.intro(chef, dayLong, session.start, session.week, session.weeks),
    when,
    dates,
    dishes: snapshot.dishes.map((dish) => dishText(dish, messages)),
    shopping: shoppingGroups(snapshot.items, locale),
    note: noteLines(snapshot.note),
    link: input.link,
  };
}

function htmlLines(lines: readonly string[]): string {
  return lines.map(escapeHtml).join("<br>");
}

/** El HTML, con el diseño compartido de los emails (emails.ts). Todo el texto va escapado. */
function emailHtml(input: MenuMessageInput, parts: MessageParts, subject: string, preheader: string): string {
  const { messages } = parts;
  const blocks: Block[] = [
    { kind: "paragraph", text: parts.intro },
    { kind: "title", text: messages.whenTitle },
    { kind: "rows", rows: parts.when },
    { kind: "title", text: messages.menuTitle },
    {
      kind: "rows",
      rows: parts.dishes.map((dish) => {
        const lines = [...(dish.description ? [dish.description] : []), dish.details, dish.allergens];
        return { label: dish.name, value: lines.join(" · "), valueHtml: htmlLines(lines) };
      }),
    },
  ];
  if (parts.shopping.length > 0) {
    blocks.push(
      { kind: "title", text: messages.shoppingTitle },
      { kind: "paragraph", text: messages.shoppingIntro(parts.chef) },
      {
        kind: "rows",
        rows: parts.shopping.map((group) => {
          const lines = group.lines.map(lineText);
          return { label: group.title, value: lines.join(", "), valueHtml: htmlLines(lines) };
        }),
      },
    );
  }
  if (parts.note.length > 0) {
    blocks.push({ kind: "title", text: messages.noteTitle(parts.chef) });
    for (const line of parts.note) blocks.push({ kind: "paragraph", text: line });
  }
  blocks.push(
    { kind: "paragraph", text: messages.confirm },
    parts.link
      ? { kind: "button", label: messages.button, href: parts.link }
      : { kind: "paragraph", text: `${messages.button}: ${messages.linkPlaceholder}` },
    { kind: "paragraph", text: messages.replyEmail },
  );
  const doc: EmailDocument = {
    locale: input.snapshot.locale,
    subject,
    preheader,
    brand: input.brand,
    heading: parts.greeting,
    blocks,
    slogan: messages.slogan,
    footer: messages.footer(input.brand),
  };
  return renderEmailDocument(doc).html;
}

/** El texto plano del email: lo mismo que el HTML, con los platos y la lista en renglones. */
function emailText(input: MenuMessageInput, parts: MessageParts): string {
  const { messages } = parts;
  const out: string[] = [parts.greeting, "", parts.intro, "", messages.whenTitle.toUpperCase()];
  for (const row of parts.when) out.push(`${row.label}: ${row.value}`);
  out.push("", messages.menuTitle.toUpperCase());
  parts.dishes.forEach((dish, index) => {
    if (index > 0) out.push("");
    out.push(`• ${dish.name}`);
    if (dish.description) out.push(`  ${dish.description}`);
    out.push(`  ${dish.details}`, `  ${dish.allergens}`);
  });
  if (parts.shopping.length > 0) {
    out.push("", messages.shoppingTitle.toUpperCase(), messages.shoppingIntro(parts.chef));
    for (const group of parts.shopping) {
      out.push("", group.title);
      for (const line of group.lines) out.push(`• ${lineText(line)}`);
    }
  }
  if (parts.note.length > 0) out.push("", messages.noteTitle(parts.chef).toUpperCase(), ...parts.note);
  out.push(
    "",
    messages.confirm,
    `${messages.button}: ${parts.link ?? messages.linkPlaceholder}`,
    "",
    messages.replyEmail,
    "",
    "--",
    messages.slogan,
    messages.footer(input.brand),
  );
  return `${out.join("\n")}\n`;
}

/** El WhatsApp: compacto, con *negrita* y _cursiva_; un plato en dos renglones. */
function whatsappText(parts: MessageParts): string {
  const { messages } = parts;
  const out: string[] = [parts.greeting, parts.intro];
  if (parts.dates) out.push("", `*${messages.allDatesLabel}:* ${parts.dates.join(" · ")}`);
  out.push("", `*${messages.menuTitle}*`);
  for (const dish of parts.dishes) {
    out.push(`• *${dish.name}*${dish.description ? ` — ${dish.description}` : ""}`, `  ${dish.details} · ${dish.allergens}`);
  }
  if (parts.shopping.length > 0) {
    out.push("", `*${messages.shoppingTitle}*`, messages.shoppingIntro(parts.chef));
    for (const group of parts.shopping) {
      out.push(`_${group.title}_`);
      for (const line of group.lines) out.push(`• ${lineText(line)}`);
    }
  }
  if (parts.note.length > 0) out.push("", `*${messages.noteTitle(parts.chef)}*`, ...parts.note);
  out.push("", messages.confirm, parts.link ?? messages.linkPlaceholder, "", messages.replyWhatsapp);
  return out.join("\n");
}

/** El email (asunto, HTML y texto) y el WhatsApp del menú de una semana, en el idioma de la foto. */
export function renderMenuMessage(input: MenuMessageInput): RenderedMenuMessage {
  const { snapshot } = input;
  const locale = snapshot.locale;
  const messages = MESSAGES[locale];
  const { session } = snapshot;
  const dayShort = formatDayMonth(session.date, locale, Number(session.date.slice(0, 4)));
  const subject = messages.subject(input.brand, dayShort, session.week, session.weeks);
  const preheader = messages.preheader(input.chefName, dayShort, session.start);
  const parts = messageParts(input);
  return {
    subject,
    html: emailHtml(input, parts, subject, preheader),
    text: emailText(input, parts),
    whatsapp: whatsappText(parts),
  };
}
