// Emails del pedido de la web (contrato §5): confirmación al cliente y aviso a Evelyn.
//
// Sin datos de salud (alergias, dietas, nota de restricciones), sin dirección y sin las notas
// libres (SPEC §6): las funciones solo reciben lo que pueden mostrar. Al cliente se le dice que
// Evelyn tendrá en cuenta sus restricciones; a Evelyn, que las vea en la app.
// Todo texto del usuario se escapa. En el asunto y en el saludo al cliente, del usuario solo va el
// nombre de pila, y solo si parece un nombre (safeFirstName): nunca un teléfono, un email ni un
// link escrito en ese campo. El mailto: del aviso a Evelyn lleva la dirección codificada.
// HTML simple con estilos en línea, sin imágenes remotas ni seguimiento, más texto plano. Con la
// identidad de la web (logotipo en texto, paleta del manual de marca) y sin fuentes remotas.
// Importes con aritmética entera; fechas sin zona horaria (son días de calendario).
// Solo sintaxis borrable: corre en Node (tests) y Deno (Edge Functions).
import type { Locale, Meal, RequestType, Slot } from "./public_request.ts";

export interface EstimateSummary {
  portions: number;
  cookMinutes: number;
  serviceCents: number;
  groceriesEstCents: number;
  totalCents: number;
}

/** Resumen del pedido que se puede mostrar en un email (nada de salud ni dirección). */
export interface RequestSummary {
  requestId: string;
  type: RequestType;
  adults: number;
  kids: number;
  days: number;
  meals: readonly Meal[];
  /** "AAAA-MM-DD" o null. */
  preferredDate: string | null;
  slot: Slot;
  /** Solo si hay restricciones, nunca cuáles. */
  hasRestrictions: boolean;
  estimate: EstimateSummary;
}

export interface ClientConfirmationInput {
  brand: string;
  chefName: string;
  /** Se usa solo el nombre de pila, si parece un nombre (safeFirstName); si no, el saludo genérico. */
  customerName: string;
  summary: RequestSummary;
  privacyUrl: string | null;
}

export interface ChefNotificationInput {
  brand: string;
  customerName: string;
  zone: string;
  phoneE164: string;
  email: string;
  whatsappOptIn: boolean;
  /** Solo si dejó notas, nunca cuáles. */
  hasNotes: boolean;
  summary: RequestSummary;
  /** Bandeja de la app web; el botón abre el pedido. */
  inboxUrl: string | null;
}

export interface RenderedEmail {
  subject: string;
  html: string;
  text: string;
}

// ---------------------------------------------------------------------------
// Textos por idioma (mismo vocabulario que la web: web/src/i18n/*.json)
// ---------------------------------------------------------------------------

interface Messages {
  types: Readonly<Record<RequestType, string>>;
  meals: { lunch: string; dinner: string; both: string };
  slots: Readonly<Record<Slot, string>>;
  adults: (n: number) => string;
  kids: (n: number) => string;
  join: (a: string, b: string) => string;
  months: readonly string[];
  weekdays: readonly string[];
  longDate: (weekday: string, day: number, month: string, year: number) => string;
  labels: {
    type: string;
    people: string;
    days: string;
    meals: string;
    date: string;
    slot: string;
    service: string;
    groceries: string;
    total: string;
    reference: string;
  };
  noDate: string;
  estimateTitle: string;
  estimateNote: string;
  client: {
    subject: (brand: string) => string;
    preheader: (chef: string) => string;
    greeting: (first: string) => string;
    intro: (chef: string) => string;
    summaryTitle: string;
    restrictions: (chef: string) => string;
    reply: string;
    privacy: string;
    /** El eslogan de la marca, el mismo de la web (common.slogan). */
    slogan: string;
    footer: (brand: string) => string;
  };
  chef: {
    subject: (first: string) => string;
    preheader: string;
    heading: string;
    intro: (name: string) => string;
    contactTitle: string;
    name: string;
    zone: string;
    phone: string;
    email: string;
    whatsapp: string;
    yes: string;
    no: string;
    summaryTitle: string;
    restrictionsYes: string;
    restrictionsNo: string;
    notes: string;
    button: string;
    footer: (brand: string) => string;
  };
}

const MESSAGES: Readonly<Record<Locale, Messages>> = {
  it: {
    types: { week: "Settimana di pasti", extra: "Evento o sessione extra" },
    meals: { lunch: "Pranzo", dinner: "Cena", both: "Pranzo e cena" },
    slots: { morning: "Mattina", afternoon: "Pomeriggio", any: "Indifferente" },
    adults: (n) => (n === 1 ? "1 adulto" : `${n} adulti`),
    kids: (n) => (n === 1 ? "1 bambino" : `${n} bambini`),
    join: (a, b) => `${a} e ${b}`,
    months: ["gennaio", "febbraio", "marzo", "aprile", "maggio", "giugno", "luglio", "agosto", "settembre", "ottobre", "novembre", "dicembre"],
    weekdays: ["domenica", "lunedì", "martedì", "mercoledì", "giovedì", "venerdì", "sabato"],
    longDate: (weekday, day, month, year) => `${weekday} ${day} ${month} ${year}`,
    labels: {
      type: "Tipo",
      people: "Persone",
      days: "Giorni",
      meals: "Pasti",
      date: "Giorno preferito",
      slot: "Fascia oraria",
      service: "Servizio",
      groceries: "Spesa stimata",
      total: "Totale stimato",
      reference: "Riferimento",
    },
    noDate: "Nessuna preferenza",
    estimateTitle: "Preventivo stimato",
    estimateNote: "La spesa si paga al costo reale dello scontrino; questa è una stima.",
    client: {
      subject: (brand) => `${brand}: abbiamo ricevuto la tua richiesta`,
      preheader: (chef) => `${chef} ti contatterà al più presto.`,
      greeting: (first) => (first ? `Grazie, ${first}!` : "Grazie!"),
      intro: (chef) => `Abbiamo ricevuto la tua richiesta. ${chef} ti contatterà al più presto per confermare giorno, orario e menù.`,
      summaryTitle: "La tua richiesta",
      restrictions: (chef) => `Hai indicato restrizioni alimentari: ${chef} ne terrà conto.`,
      reply: "Vuoi aggiungere o cambiare qualcosa? Rispondi a questa email.",
      privacy: "Informativa privacy",
      slogan: "Cucina autentica, a casa tua.",
      footer: (brand) => `Ricevi questa email perché hai inviato una richiesta dal sito di ${brand}.`,
    },
    chef: {
      subject: (first) => (first ? `Nuova richiesta da ${first}` : "Nuova richiesta dal sito"),
      preheader: "Aprila nell'app per rispondere.",
      heading: "Nuova richiesta dal sito",
      intro: (name) => `${name} ha inviato una richiesta. Aprila nell'app per vedere tutti i dettagli e rispondere.`,
      contactTitle: "Contatto",
      name: "Nome",
      zone: "Zona",
      phone: "Telefono",
      email: "Email",
      whatsapp: "Conferma su WhatsApp",
      yes: "Sì",
      no: "No",
      summaryTitle: "Richiesta",
      restrictionsYes: "Ha indicato restrizioni alimentari: le trovi nell'app.",
      restrictionsNo: "Nessuna restrizione alimentare indicata.",
      notes: "Ha lasciato delle note: le trovi nell'app.",
      button: "Apri la richiesta",
      footer: (brand) => `Avviso automatico di ${brand}.`,
    },
  },
  es: {
    types: { week: "Semana de comidas", extra: "Evento o sesión extra" },
    meals: { lunch: "Almuerzo", dinner: "Cena", both: "Almuerzo y cena" },
    slots: { morning: "Mañana", afternoon: "Tarde", any: "Indiferente" },
    adults: (n) => (n === 1 ? "1 adulto" : `${n} adultos`),
    kids: (n) => (n === 1 ? "1 niño" : `${n} niños`),
    join: (a, b) => `${a} y ${b}`,
    months: ["enero", "febrero", "marzo", "abril", "mayo", "junio", "julio", "agosto", "septiembre", "octubre", "noviembre", "diciembre"],
    weekdays: ["domingo", "lunes", "martes", "miércoles", "jueves", "viernes", "sábado"],
    longDate: (weekday, day, month, year) => `${weekday}, ${day} de ${month} de ${year}`,
    labels: {
      type: "Tipo",
      people: "Personas",
      days: "Días",
      meals: "Comidas",
      date: "Día preferido",
      slot: "Franja horaria",
      service: "Servicio",
      groceries: "Compra estimada",
      total: "Total estimado",
      reference: "Referencia",
    },
    noDate: "Sin preferencia",
    estimateTitle: "Presupuesto estimado",
    estimateNote: "La compra se paga al precio real del ticket; esto es una estimación.",
    client: {
      subject: (brand) => `${brand}: hemos recibido tu solicitud`,
      preheader: (chef) => `${chef} te contactará lo antes posible.`,
      greeting: (first) => (first ? `¡Gracias, ${first}!` : "¡Gracias!"),
      intro: (chef) => `Hemos recibido tu solicitud. ${chef} te contactará lo antes posible para confirmar el día, el horario y el menú.`,
      summaryTitle: "Tu solicitud",
      restrictions: (chef) => `Indicaste restricciones alimentarias: ${chef} las tendrá en cuenta.`,
      reply: "¿Quieres añadir o cambiar algo? Responde a este email.",
      privacy: "Política de privacidad",
      slogan: "Cocina auténtica, en tu casa.",
      footer: (brand) => `Recibes este email porque enviaste una solicitud desde la web de ${brand}.`,
    },
    chef: {
      subject: (first) => (first ? `Nueva solicitud de ${first}` : "Nueva solicitud desde la web"),
      preheader: "Ábrela en la app para responder.",
      heading: "Nueva solicitud desde la web",
      intro: (name) => `${name} envió una solicitud. Ábrela en la app para ver todos los datos y responder.`,
      contactTitle: "Contacto",
      name: "Nombre",
      zone: "Zona",
      phone: "Teléfono",
      email: "Email",
      whatsapp: "Confirmación por WhatsApp",
      yes: "Sí",
      no: "No",
      summaryTitle: "Solicitud",
      restrictionsYes: "Indicó restricciones alimentarias: las ves en la app.",
      restrictionsNo: "No indicó restricciones alimentarias.",
      notes: "Dejó notas: las ves en la app.",
      button: "Abrir en la bandeja",
      footer: (brand) => `Aviso automático de ${brand}.`,
    },
  },
  en: {
    types: { week: "A week of meals", extra: "Event or extra session" },
    meals: { lunch: "Lunch", dinner: "Dinner", both: "Lunch and dinner" },
    slots: { morning: "Morning", afternoon: "Afternoon", any: "Either" },
    adults: (n) => (n === 1 ? "1 adult" : `${n} adults`),
    kids: (n) => (n === 1 ? "1 child" : `${n} children`),
    join: (a, b) => `${a} and ${b}`,
    months: ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"],
    weekdays: ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"],
    longDate: (weekday, day, month, year) => `${weekday} ${day} ${month} ${year}`,
    labels: {
      type: "Type",
      people: "People",
      days: "Days",
      meals: "Meals",
      date: "Preferred day",
      slot: "Time of day",
      service: "Service",
      groceries: "Estimated groceries",
      total: "Estimated total",
      reference: "Reference",
    },
    noDate: "No preference",
    estimateTitle: "Estimated quote",
    estimateNote: "Groceries are charged at the actual receipt cost; this is an estimate.",
    client: {
      subject: (brand) => `${brand}: we've received your request`,
      preheader: (chef) => `${chef} will contact you as soon as possible.`,
      greeting: (first) => (first ? `Thank you, ${first}!` : "Thank you!"),
      intro: (chef) => `We've received your request. ${chef} will contact you as soon as possible to confirm the day, time and menu.`,
      summaryTitle: "Your request",
      restrictions: (chef) => `You mentioned dietary restrictions: ${chef} will take them into account.`,
      reply: "Want to add or change something? Just reply to this email.",
      privacy: "Privacy policy",
      slogan: "Authentic cooking, in your home.",
      footer: (brand) => `You're receiving this email because you sent a request through the ${brand} website.`,
    },
    chef: {
      subject: (first) => (first ? `New request from ${first}` : "New request from the website"),
      preheader: "Open it in the app to reply.",
      heading: "New request from the website",
      intro: (name) => `${name} sent a request. Open it in the app to see all the details and reply.`,
      contactTitle: "Contact",
      name: "Name",
      zone: "Area",
      phone: "Phone",
      email: "Email",
      whatsapp: "WhatsApp confirmation",
      yes: "Yes",
      no: "No",
      summaryTitle: "Request",
      restrictionsYes: "They mentioned dietary restrictions: see them in the app.",
      restrictionsNo: "No dietary restrictions mentioned.",
      notes: "They left some notes: see them in the app.",
      button: "Open in the inbox",
      footer: (brand) => `Automatic notice from ${brand}.`,
    },
  },
};

// ---------------------------------------------------------------------------
// Formatos (puros, también para tests)
// ---------------------------------------------------------------------------

const HTML_ESCAPES: Readonly<Record<string, string>> = { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" };

export function escapeHtml(value: string): string {
  return value.replace(/[&<>"']/g, (char) => HTML_ESCAPES[char] ?? char);
}

/** Primera palabra del nombre, con tope de 40 caracteres. */
export function firstName(fullName: string): string {
  return (fullName.trim().split(/\s+/)[0] ?? "").slice(0, 40);
}

/**
 * Una palabra que parece un nombre: letras (cualquier alfabeto, con acentos) y, entre ellas,
 * apóstrofo o guion ("José", "D'Angelo", "Jean-Luc"), hasta 30 caracteres. Sin puntos, dígitos,
 * "@", "/" ni ":": ni un teléfono, ni un email, ni un dominio o link ("bit.ly/…", "x.com").
 */
const NAME_WORD = /^\p{L}[\p{L}\p{M}'’-]{0,29}$/u;

/**
 * Nombre de pila para lo que sale hacia afuera, o "" si la primera palabra no parece un nombre:
 * el asunto del aviso a Evelyn (se ve en la bandeja y en las notificaciones del celular), el saludo
 * de la confirmación al cliente y el parámetro del WhatsApp. Esos dos últimos llegan a un email o
 * a un número que nadie verificó: no pueden llevar un link escrito en el formulario.
 */
export function safeFirstName(fullName: string): string {
  const first = firstName(fullName);
  return NAME_WORD.test(first) ? first : "";
}

/**
 * href mailto: con la dirección codificada (sin el "@"): así ningún "?", "&" o "#" escrito en el
 * campo del email agrega destinatarios ocultos (bcc), cc ni un cuerpo armado al responder.
 */
export function mailtoHref(email: string): string {
  const at = email.lastIndexOf("@");
  if (at < 0) return `mailto:${encodeURIComponent(email)}`;
  return `mailto:${encodeURIComponent(email.slice(0, at))}@${encodeURIComponent(email.slice(at + 1))}`;
}

/**
 * Dirección escapada para mostrar, con puntos de corte después de la "@" y antes de cada punto (como
 * se parte una dirección en un texto): en el teléfono, una dirección larga baja de línea por ahí y no
 * en medio de una palabra. Se escapa primero: las entidades no tienen "@" ni ".", y el texto ya no
 * tiene "<" con que armar etiquetas.
 */
export function emailWithBreaks(email: string): string {
  return escapeHtml(email).replaceAll("@", "@<wbr>").replaceAll(".", "<wbr>.");
}

/** Importe en centavos enteros: "1.234,56 €" (it, es) o "€1,234.56" (en). Sin pasar por decimales. */
export function formatCents(cents: number, locale: Locale): string {
  if (!Number.isInteger(cents) || cents < 0) throw new RangeError(`Importe inválido en centavos: ${cents}`);
  const rest = cents % 100;
  const units = String((cents - rest) / 100).replace(/\B(?=(\d{3})+(?!\d))/g, locale === "en" ? "," : ".");
  const decimals = String(rest).padStart(2, "0");
  return locale === "en" ? `€${units}.${decimals}` : `${units},${decimals} €`;
}

/** "2026-10-25" → "domenica 25 ottobre 2026" / "domingo, 25 de octubre de 2026" / "Sunday 25 October 2026". */
export function formatDateLong(iso: string, locale: Locale): string {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(iso);
  if (!match) return iso;
  const year = Number(match[1]);
  const month = Number(match[2]);
  const day = Number(match[3]);
  const date = new Date(Date.UTC(year, month - 1, day));
  if (date.getUTCMonth() !== month - 1 || date.getUTCDate() !== day) return iso;
  const messages = MESSAGES[locale];
  return messages.longDate(messages.weekdays[date.getUTCDay()] ?? "", day, messages.months[month - 1] ?? "", year);
}

export function formatPeople(adults: number, kids: number, locale: Locale): string {
  const messages = MESSAGES[locale];
  const parts: string[] = [];
  if (adults > 0) parts.push(messages.adults(adults));
  if (kids > 0) parts.push(messages.kids(kids));
  const [first, second] = parts;
  if (first !== undefined && second !== undefined) return messages.join(first, second);
  return first ?? messages.adults(0);
}

/** Nombre a mostrar de MAIL_FROM ("Radici <ciao@…>" → "Radici"). */
export function brandFromMailFrom(mailFrom: string | null | undefined, fallback = "Radici"): string {
  const match = mailFrom ? /^\s*"?([^"<]*?)"?\s*<[^<>]+>\s*$/.exec(mailFrom) : null;
  const name = match?.[1]?.trim();
  return name ? name : fallback;
}

/** La URL si es http(s); si no, null (nunca javascript:, data:, etc.). */
export function safeHttpUrl(url: string | null | undefined): string | null {
  if (!url) return null;
  const trimmed = url.trim();
  try {
    const parsed = new URL(trimmed);
    return parsed.protocol === "https:" || parsed.protocol === "http:" ? trimmed : null;
  } catch {
    return null;
  }
}

/** Enlace directo al pedido en la bandeja (app Flutter web con rutas en el hash). */
export function inboxRequestUrl(inboxUrl: string, requestId: string): string {
  return `${inboxUrl.replace(/#.*$/, "")}#/richieste/${encodeURIComponent(requestId)}`;
}

/** Página de privacidad de la web, en el idioma del cliente. */
export function privacyPageUrl(siteUrl: string, locale: Locale): string {
  return `${siteUrl.replace(/\/+$/, "")}/privacy/${locale === "it" ? "" : `?lang=${locale}`}`;
}

// ---------------------------------------------------------------------------
// Armado del HTML y del texto
// ---------------------------------------------------------------------------

// Paleta de la web (web/src/styles/base.css), con el contraste verificado (WCAG AA) sobre la tarjeta.
const COLOR = {
  page: "#f5ede1", // crema
  card: "#fbf7f1", // crema clara
  border: "#dbc9b4", // lino
  rule: "#cdb9a1", // líneas entre filas
  text: "#2c2b20", // tinta
  muted: "#5b5847",
  accent: "#4a5a3c", // oliva
  onAccent: "#f5ede1", // crema sobre oliva
};
// Sin fuentes web: en un email serían un recurso remoto y casi ningún cliente las carga. Palatino y
// sus parecidas tienen números de caja alta (Georgia no) y se acercan a Cormorant; Cinzel solo si
// quien lee la tiene instalada.
const FONT = "'Palatino Linotype',Palatino,'Book Antiqua',Georgia,'Times New Roman',serif";
const FONT_DISPLAY = `Cinzel,'Trajan Pro',${FONT}`;
/** Rótulo del logotipo: parte de la marca, en italiano en todos los idiomas (como en la web). */
const BRAND_TAGLINE = "Cucina privata";

/** Fila etiqueta / valor. `valueHtml` ya viene escapado (puede traer un link). */
interface Row {
  label: string;
  value: string;
  valueHtml?: string;
}

type Block =
  | { kind: "paragraph"; text: string }
  | { kind: "title"; text: string }
  | { kind: "rows"; rows: Row[] }
  | { kind: "note"; text: string }
  | { kind: "button"; label: string; href: string }
  | { kind: "link"; label: string; href: string };

interface EmailDocument {
  locale: Locale;
  subject: string;
  preheader: string;
  brand: string;
  heading: string;
  blocks: Block[];
  /** Eslogan arriba del pie (solo en la confirmación al cliente). */
  slogan: string | null;
  footer: string;
}

function blockHtml(block: Block): string {
  switch (block.kind) {
    case "paragraph":
      return `<p style="margin:0 0 16px;font-size:17px;line-height:1.55;">${escapeHtml(block.text)}</p>`;
    case "title":
      // Rótulo como los de la web: mayúsculas espaciadas en oliva.
      return (
        `<h2 style="margin:28px 0 8px;font-family:${FONT_DISPLAY};font-size:13px;font-weight:normal;line-height:1.3;` +
        `letter-spacing:0.16em;text-transform:uppercase;color:${COLOR.accent};">${escapeHtml(block.text)}</h2>`
      );
    case "note":
      return `<p style="margin:8px 0 16px;font-size:15px;line-height:1.5;font-style:italic;color:${COLOR.muted};">${escapeHtml(block.text)}</p>`;
    case "rows":
      // Letra y color también en esta tabla: Outlook de Windows no los hereda en tablas anidadas
      // (salía Times New Roman). El valor puede partir una palabra que no entra (un email largo,
      // nombre y zona son texto libre): si no, la tabla ensancha la tarjeta más allá del teléfono.
      return (
        `<table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="border-collapse:collapse;` +
        `font-family:${FONT};color:${COLOR.text};font-size:16px;line-height:1.45;">` +
        block.rows
          .map(
            (row) =>
              `<tr><td style="padding:7px 12px 7px 0;border-top:1px solid ${COLOR.rule};color:${COLOR.muted};vertical-align:top;width:45%;">` +
              `${escapeHtml(row.label)}</td><td style="padding:7px 0;border-top:1px solid ${COLOR.rule};vertical-align:top;` +
              `word-break:break-word;overflow-wrap:anywhere;">${row.valueHtml ?? escapeHtml(row.value)}</td></tr>`,
          )
          .join("") +
        `</table>`
      );
    case "button":
      // Como los botones de la web: oliva y crema, esquinas casi rectas, versalitas.
      return (
        `<table role="presentation" cellspacing="0" cellpadding="0" style="margin:28px 0 8px;"><tr>` +
        `<td style="border-radius:2px;background:${COLOR.accent};">` +
        `<a href="${escapeHtml(block.href)}" style="display:inline-block;padding:13px 26px;font-family:${FONT_DISPLAY};font-size:17px;` +
        `letter-spacing:0.06em;font-variant:small-caps;color:${COLOR.onAccent};text-decoration:none;border-radius:2px;">` +
        `${escapeHtml(block.label)}</a></td></tr></table>`
      );
    case "link":
      return (
        `<p style="margin:16px 0 0;font-size:15px;line-height:1.5;">` +
        `<a href="${escapeHtml(block.href)}" style="color:${COLOR.accent};text-decoration:underline;">${escapeHtml(block.label)}</a></p>`
      );
  }
}

function blockText(block: Block): string {
  switch (block.kind) {
    case "paragraph":
    case "note":
      return block.text;
    case "title":
      return block.text.toUpperCase();
    case "rows":
      return block.rows.map((row) => `${row.label}: ${row.value}`).join("\n");
    case "button":
    case "link":
      return `${block.label}: ${block.href}`;
  }
}

/** Texto plano: un bloque por párrafo; el título queda pegado a sus filas. */
function plainText(doc: EmailDocument): string {
  let text = doc.heading;
  let previous: Block["kind"] | null = null;
  for (const block of doc.blocks) {
    text += (previous === "title" ? "\n" : "\n\n") + blockText(block);
    previous = block.kind;
  }
  return `${text}\n\n--\n${doc.slogan ? `${doc.slogan}\n` : ""}${doc.footer}\n`;
}

/**
 * Logotipo en texto, sin imágenes: el nombre en versalitas sobre el filete y el rótulo debajo, como en
 * el manual de marca. El filete es el borde de la celda del nombre: mide lo que mide el nombre. En las
 * dos celdas, el padding izquierdo compensa el espaciado que queda después de la última letra (así el
 * filete sobresale lo mismo a cada lado y el rótulo queda centrado).
 * - Espaciado en px: Outlook de Windows (Word) resuelve los em contra 12 pt y no contra la letra de
 *   la celda, y el rótulo terminaba casi tan ancho como el filete.
 * - El filete toma el color del texto (currentColor, con la tinta de respaldo): Outlook en modo oscuro
 *   aclara el texto pero no los bordes, y un filete tinta desaparecía sobre el fondo oscuro.
 */
function logoHtml(brand: string): string {
  return (
    `<table role="presentation" cellspacing="0" cellpadding="0" style="margin:0 auto;"><tr>` +
    `<td align="center" style="padding:0 3px 8px 6px;border-bottom:1px solid ${COLOR.text};border-bottom-color:currentColor;` +
    `font-family:${FONT_DISPLAY};font-size:40px;line-height:1;letter-spacing:3.2px;font-variant:small-caps;color:${COLOR.text};">` +
    `${escapeHtml(brand)}</td>` +
    `</tr><tr>` +
    // El rótulo, más angosto que el nombre (entre 70 y 80 % del filete según la letra; en el manual, 79 %).
    `<td align="center" lang="it" style="padding:9px 0 0 2px;font-family:${FONT_DISPLAY};font-size:9px;line-height:1.2;` +
    `letter-spacing:2.3px;text-transform:uppercase;color:${COLOR.text};">${escapeHtml(BRAND_TAGLINE)}</td>` +
    `</tr></table>`
  );
}

function render(doc: EmailDocument): RenderedEmail {
  const slogan = doc.slogan
    ? `<p style="margin:0 0 10px;font-size:17px;line-height:1.4;font-style:italic;color:${COLOR.text};">${escapeHtml(doc.slogan)}</p>`
    : "";
  const html =
    `<!doctype html>` +
    `<html lang="${doc.locale}"><head><meta charset="utf-8">` +
    `<meta name="viewport" content="width=device-width, initial-scale=1">` +
    `<meta name="x-apple-disable-message-reformatting"><meta name="color-scheme" content="light">` +
    `<title>${escapeHtml(doc.subject)}</title></head>` +
    `<body style="margin:0;padding:0;background:${COLOR.page};">` +
    `<div style="display:none;max-height:0;overflow:hidden;">${escapeHtml(doc.preheader)}</div>` +
    `<table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="background:${COLOR.page};">` +
    `<tr><td align="center" style="padding:24px 12px;">` +
    `<table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="max-width:560px;background:${COLOR.card};` +
    `border:1px solid ${COLOR.border};border-radius:2px;font-family:${FONT};font-variant-numeric:lining-nums;color:${COLOR.text};">` +
    `<tr><td align="center" style="padding:32px 24px 8px;">${logoHtml(doc.brand)}</td></tr>` +
    `<tr><td style="padding:20px 24px 24px;">` +
    `<h1 style="margin:0 0 16px;font-size:26px;font-weight:normal;line-height:1.25;">${escapeHtml(doc.heading)}</h1>` +
    doc.blocks.map(blockHtml).join("") +
    `</td></tr>` +
    `<tr><td align="center" style="padding:20px 24px 28px;border-top:1px solid ${COLOR.border};font-size:13px;line-height:1.5;color:${COLOR.muted};">` +
    `${slogan}${escapeHtml(doc.footer)}</td></tr>` +
    `</table></td></tr></table></body></html>`;
  return { subject: doc.subject, html, text: plainText(doc) };
}

function summaryRows(summary: RequestSummary, messages: Messages, locale: Locale): Row[] {
  const meals = summary.meals.length > 1 ? messages.meals.both : messages.meals[summary.meals[0] ?? "dinner"];
  return [
    { label: messages.labels.type, value: messages.types[summary.type] },
    { label: messages.labels.people, value: formatPeople(summary.adults, summary.kids, locale) },
    { label: messages.labels.days, value: String(summary.days) },
    { label: messages.labels.meals, value: meals },
    { label: messages.labels.date, value: summary.preferredDate ? formatDateLong(summary.preferredDate, locale) : messages.noDate },
    { label: messages.labels.slot, value: messages.slots[summary.slot] },
  ];
}

function estimateBlocks(summary: RequestSummary, messages: Messages, locale: Locale): Block[] {
  const { estimate } = summary;
  return [
    { kind: "title", text: messages.estimateTitle },
    {
      kind: "rows",
      rows: [
        { label: messages.labels.service, value: formatCents(estimate.serviceCents, locale) },
        { label: messages.labels.groceries, value: formatCents(estimate.groceriesEstCents, locale) },
        {
          label: messages.labels.total,
          value: formatCents(estimate.totalCents, locale),
          valueHtml: `<strong>${escapeHtml(formatCents(estimate.totalCents, locale))}</strong>`,
        },
      ],
    },
    { kind: "note", text: messages.estimateNote },
  ];
}

/** Confirmación al cliente, en su idioma. */
export function renderClientConfirmation(input: ClientConfirmationInput, locale: Locale): RenderedEmail {
  const messages = MESSAGES[locale];
  const { summary } = input;
  const privacyUrl = safeHttpUrl(input.privacyUrl);
  const blocks: Block[] = [
    { kind: "paragraph", text: messages.client.intro(input.chefName) },
    { kind: "title", text: messages.client.summaryTitle },
    { kind: "rows", rows: summaryRows(summary, messages, locale) },
  ];
  if (summary.hasRestrictions) blocks.push({ kind: "note", text: messages.client.restrictions(input.chefName) });
  blocks.push(...estimateBlocks(summary, messages, locale));
  blocks.push({ kind: "paragraph", text: messages.client.reply });
  if (privacyUrl) blocks.push({ kind: "link", label: messages.client.privacy, href: privacyUrl });
  blocks.push({ kind: "note", text: `${messages.labels.reference}: ${summary.requestId.slice(0, 8)}` });

  return render({
    locale,
    subject: messages.client.subject(input.brand),
    preheader: messages.client.preheader(input.chefName),
    brand: input.brand,
    heading: messages.client.greeting(safeFirstName(input.customerName)),
    blocks,
    slogan: messages.client.slogan,
    footer: messages.client.footer(input.brand),
  });
}

/** Aviso a Evelyn, en CHEF_LOCALE. */
export function renderChefNotification(input: ChefNotificationInput, locale: Locale): RenderedEmail {
  const messages = MESSAGES[locale];
  const { summary } = input;
  const inboxUrl = safeHttpUrl(input.inboxUrl);
  const contact: Row[] = [
    { label: messages.chef.name, value: input.customerName },
    { label: messages.chef.zone, value: input.zone },
    {
      label: messages.chef.phone,
      value: input.phoneE164,
      valueHtml: `<a href="${escapeHtml(`tel:${input.phoneE164}`)}" style="color:${COLOR.accent};">${escapeHtml(input.phoneE164)}</a>`,
    },
    {
      label: messages.chef.email,
      value: input.email,
      valueHtml: `<a href="${escapeHtml(mailtoHref(input.email))}" style="color:${COLOR.accent};">${emailWithBreaks(input.email)}</a>`,
    },
    { label: messages.chef.whatsapp, value: input.whatsappOptIn ? messages.chef.yes : messages.chef.no },
  ];
  const blocks: Block[] = [
    { kind: "paragraph", text: messages.chef.intro(input.customerName) },
    { kind: "title", text: messages.chef.contactTitle },
    { kind: "rows", rows: contact },
    { kind: "title", text: messages.chef.summaryTitle },
    { kind: "rows", rows: summaryRows(summary, messages, locale) },
    { kind: "note", text: summary.hasRestrictions ? messages.chef.restrictionsYes : messages.chef.restrictionsNo },
  ];
  if (input.hasNotes) blocks.push({ kind: "note", text: messages.chef.notes });
  blocks.push(...estimateBlocks(summary, messages, locale));
  if (inboxUrl) blocks.push({ kind: "button", label: messages.chef.button, href: inboxRequestUrl(inboxUrl, summary.requestId) });

  return render({
    locale,
    subject: messages.chef.subject(safeFirstName(input.customerName)),
    preheader: messages.chef.preheader,
    brand: input.brand,
    heading: messages.chef.heading,
    blocks,
    slogan: null,
    footer: messages.chef.footer(input.brand),
  });
}
