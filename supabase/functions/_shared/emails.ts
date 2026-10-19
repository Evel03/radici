// Emails del pedido de la web (contrato §5): confirmación al cliente y aviso a Evelyn.
//
// Sin datos de salud (alergias, dietas, nota de restricciones), sin dirección y sin las notas
// libres (SPEC §6): las funciones solo reciben lo que pueden mostrar. Al cliente se le dice que
// Evelyn tendrá en cuenta sus restricciones; a Evelyn, que las vea en la app.
// Todo texto del usuario se escapa. En el asunto, del usuario solo va el nombre de pila, y solo
// si parece un nombre (subjectFirstName): nunca un teléfono o un email escrito en ese campo.
// HTML simple con estilos en línea, sin imágenes remotas ni seguimiento, más texto plano.
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
  /** Se usa solo el nombre de pila. */
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

/** Primera palabra del nombre, con tope de 40 caracteres (saludo del email y WhatsApp). */
export function firstName(fullName: string): string {
  return (fullName.trim().split(/\s+/)[0] ?? "").slice(0, 40);
}

/** Letras (cualquier alfabeto, con acentos) y, entre ellas, apóstrofo, guion o punto: "José", "D'Angelo", "Jean-Luc". */
const NAME_WORD = /^\p{L}[\p{L}\p{M}'’.-]*$/u;

/**
 * Nombre de pila para un asunto, o "" si la primera palabra no parece un nombre. Cualquiera
 * escribe lo que quiere en "nombre": si trae dígitos, "@", "+" u otros signos (un teléfono, un
 * email) no va al asunto, que se ve en la bandeja y en las notificaciones del celular.
 */
export function subjectFirstName(fullName: string): string {
  const first = firstName(fullName);
  return NAME_WORD.test(first) ? first : "";
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

const COLOR = { page: "#fbf6ee", card: "#ffffff", border: "#e2d4c1", text: "#1c1713", muted: "#6b5d52", accent: "#a3431c" };
const FONT = "-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif";

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
  footer: string;
}

function blockHtml(block: Block): string {
  switch (block.kind) {
    case "paragraph":
      return `<p style="margin:0 0 16px;font-size:16px;line-height:1.5;">${escapeHtml(block.text)}</p>`;
    case "title":
      return `<h2 style="margin:24px 0 8px;font-size:17px;line-height:1.3;color:${COLOR.text};">${escapeHtml(block.text)}</h2>`;
    case "note":
      return `<p style="margin:8px 0 16px;font-size:14px;line-height:1.5;color:${COLOR.muted};">${escapeHtml(block.text)}</p>`;
    case "rows":
      return (
        `<table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="border-collapse:collapse;font-size:15px;line-height:1.4;">` +
        block.rows
          .map(
            (row) =>
              `<tr><td style="padding:6px 12px 6px 0;border-top:1px solid ${COLOR.border};color:${COLOR.muted};vertical-align:top;width:45%;">` +
              `${escapeHtml(row.label)}</td><td style="padding:6px 0;border-top:1px solid ${COLOR.border};vertical-align:top;">` +
              `${row.valueHtml ?? escapeHtml(row.value)}</td></tr>`,
          )
          .join("") +
        `</table>`
      );
    case "button":
      return (
        `<table role="presentation" cellspacing="0" cellpadding="0" style="margin:24px 0 8px;"><tr>` +
        `<td style="border-radius:8px;background:${COLOR.accent};">` +
        `<a href="${escapeHtml(block.href)}" style="display:inline-block;padding:12px 22px;font-size:16px;font-weight:600;` +
        `color:#ffffff;text-decoration:none;border-radius:8px;">${escapeHtml(block.label)}</a></td></tr></table>`
      );
    case "link":
      return (
        `<p style="margin:16px 0 0;font-size:14px;line-height:1.5;">` +
        `<a href="${escapeHtml(block.href)}" style="color:${COLOR.accent};">${escapeHtml(block.label)}</a></p>`
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
  return `${text}\n\n--\n${doc.footer}\n`;
}

function render(doc: EmailDocument): RenderedEmail {
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
    `border:1px solid ${COLOR.border};border-radius:12px;font-family:${FONT};color:${COLOR.text};">` +
    `<tr><td style="padding:24px 24px 0;font-size:14px;font-weight:700;letter-spacing:0.02em;color:${COLOR.accent};">` +
    `${escapeHtml(doc.brand)}</td></tr>` +
    `<tr><td style="padding:12px 24px 24px;">` +
    `<h1 style="margin:0 0 16px;font-size:22px;line-height:1.3;">${escapeHtml(doc.heading)}</h1>` +
    doc.blocks.map(blockHtml).join("") +
    `</td></tr>` +
    `<tr><td style="padding:16px 24px 24px;border-top:1px solid ${COLOR.border};font-size:12px;line-height:1.5;color:${COLOR.muted};">` +
    `${escapeHtml(doc.footer)}</td></tr>` +
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
    heading: messages.client.greeting(firstName(input.customerName)),
    blocks,
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
      valueHtml: `<a href="${escapeHtml(`mailto:${input.email}`)}" style="color:${COLOR.accent};">${escapeHtml(input.email)}</a>`,
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
    subject: messages.chef.subject(subjectFirstName(input.customerName)),
    preheader: messages.chef.preheader,
    brand: input.brand,
    heading: messages.chef.heading,
    blocks,
    footer: messages.chef.footer(input.brand),
  });
}
