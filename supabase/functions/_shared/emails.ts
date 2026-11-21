// Emails del pedido de la web (contrato §5): confirmación al cliente y aviso a Evelyn.
//
// Sin datos de salud (alergias, dietas, nota de restricciones), sin dirección y sin las notas
// libres (SPEC §6): las funciones solo reciben lo que pueden mostrar. De las alergias, solo qué
// contestó el cliente (AllergyAnswer), nunca cuáles: a Evelyn, que nadie tiene, que las vea en la
// app o, sin respuesta, que pregunte antes del menú. Al cliente, solo que confirmó que nadie tiene:
// su dirección no está verificada y "hay alergias" también es un dato de salud.
// Todo texto del usuario se escapa. En el asunto y en el saludo al cliente, del usuario solo va el
// nombre de pila, y solo si parece un nombre (safeFirstName): nunca un teléfono, un email ni un
// link escrito en ese campo. El mailto: del aviso a Evelyn lleva la dirección codificada.
// HTML simple con estilos en línea, sin imágenes remotas ni seguimiento, más texto plano. Con la
// identidad de la web (logotipo en texto, paleta del manual de marca) y sin fuentes remotas.
// Importes con aritmética entera; fechas sin zona horaria (son días de calendario).
// Precio por semana (SPEC §5.1): con precio automático, el servicio por semana, el de todas las semanas
// y el ahorro; sin él, quién prepara el presupuesto. La compra la hace el cliente con la lista que le
// manda Evelyn (decisión del 19/11/2026): ningún email la estima; al cliente se le recuerda, a Evelyn no.
// Menù (versión 4, 19/11/2026): los platos que eligió el cliente en la web, con los nombres de la receta en
// el idioma del email (o en italiano si no están traducidos). A Evelyn, cuáles y de cuántos días, o que lo
// propone ella; al cliente, cuáles y que Evelyn le confirma el menù. Nunca sus alérgenos.
// Solo sintaxis borrable: corre en Node (tests) y Deno (Edge Functions).
import { localizedText, type MenuChoice } from "./menu.ts";
import { weeklyDates, type Locale, type Meal, type RequestType, type Slot } from "./public_request.ts";
import type { NoAutoPriceReason } from "./quote.ts";

/** Lo que el email dice del precio: la estimación del motor con las tarifas de la cocinera. */
export type EstimateSummary =
  | {
      autoPrice: true;
      /** Servicio de cada semana. */
      weeklyServiceCents: number;
      /** Servicio de todas las semanas. */
      serviceCents: number;
      savingsCents: number;
      /** La tarifa por semana sin descuento: frente a qué es el ahorro. */
      regularWeeklyCents: number;
    }
  | {
      autoPrice: false;
      reason: NoAutoPriceReason;
      /** Hasta cuántas personas hay precio automático: por qué este pedido no lo tiene. */
      maxPeople: number;
    };

/**
 * Qué contestó el cliente a la pregunta de alergias, sin decir cuáles:
 * - "none": confirmó que nadie de quienes van a comer tiene alergias, intolerancias ni celiaquía;
 * - "listed": las escribió (Evelyn las ve en la app);
 * - "unknown": no hay respuesta (un pedido anterior a la pregunta).
 * El aviso a Evelyn dice los tres casos; la confirmación al cliente, solo "none".
 */
export type AllergyAnswer = "none" | "listed" | "unknown";

/**
 * La respuesta a partir de lo guardado. Con restricciones, siempre "listed" (más vale avisar de más);
 * sin ellas, "none" solo si lo confirmó y si no, "unknown".
 */
export function allergyAnswer(noAllergies: boolean | null | undefined, hasRestrictions: boolean): AllergyAnswer {
  if (hasRestrictions) return "listed";
  return noAllergies === true ? "none" : "unknown";
}

/** Resumen del pedido que se puede mostrar en un email (nada de salud ni dirección). */
export interface RequestSummary {
  requestId: string;
  type: RequestType;
  adults: number;
  kids: number;
  days: number;
  meals: readonly Meal[];
  /** Semanas del pedido semanal (una sesión por semana); 1 en una sesión extra. */
  weeks: number;
  /** "AAAA-MM-DD" o null: el día de la primera semana. Las siguientes, el mismo día de cada semana. */
  preferredDate: string | null;
  slot: Slot;
  /** Qué contestó sobre alergias, nunca cuáles. */
  allergies: AllergyAnswer;
  estimate: EstimateSummary;
  /** Los platos que eligió en la web (los que guardó la base, en orden); [] si el menù lo propone Evelyn. */
  menu: readonly MenuChoice[];
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
  /** Los meses abreviados, como los da Intl (it-IT, es-ES, en-GB): para las fechas de las semanas siguientes. */
  monthsShort: readonly string[];
  weekdays: readonly string[];
  longDate: (weekday: string, day: number, month: string, year: number) => string;
  labels: {
    type: string;
    weeks: string;
    people: string;
    days: string;
    /** Los días de un pedido semanal son de cada semana. */
    daysPerWeek: string;
    meals: string;
    date: string;
    /** Las fechas de las semanas siguientes (el mismo día de cada semana). */
    nextDates: string;
    slot: string;
    service: string;
    weeklyService: string;
    /** El servicio de todas las semanas (más de una). */
    serviceWeeks: (weeks: number) => string;
    savings: string;
    reference: string;
  };
  /** "40,00 € rispetto a 150,00 € a settimana". */
  savingsValue: (savings: string, regular: string) => string;
  noDate: string;
  estimateTitle: string;
  /** Con precio automático, debajo del importe: que es una estimación (al cliente, el precio final se lo confirma Evelyn). */
  estimateNote: string;
  client: {
    subject: (brand: string) => string;
    preheader: (chef: string) => string;
    greeting: (first: string) => string;
    intro: (chef: string) => string;
    /** Sin precio automático: quién prepara el presupuesto del servicio, y por qué. */
    noAutoPrice: Readonly<Record<NoAutoPriceReason, (chef: string, maxPeople: number) => string>>;
    /** La compra la hace el cliente, con la lista que le manda la cocinera (la misma frase que la web). */
    shopping: (chef: string) => string;
    summaryTitle: string;
    /** Fila del resumen con los platos que eligió. */
    menuChosen: string;
    /** Debajo del resumen: que la cocinera le confirma el menù y, si eligió menos platos que días, el resto. */
    menuConfirm: (chef: string, complete: boolean) => string;
    /**
     * Confirmó que nadie tiene alergias: se lo repite, para que vea si se equivocó. Con alergias escritas
     * o sin respuesta no se dice nada (el email no está verificado; lo que contestó lo vio al enviar).
     */
    allergiesNone: string;
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
    /** Sin precio automático: que prepare ella el presupuesto, y por qué. */
    noAutoPrice: Readonly<Record<NoAutoPriceReason, (maxPeople: number) => string>>;
    /** Una línea por respuesta: nadie tiene, las ve en la app, o que pregunte (pedido sin respuesta). */
    allergies: Readonly<Record<AllergyAnswer, string>>;
    /** «Menù scelto dal cliente (2 di 5 giorni): Lasagne · Minestrone». */
    menuChosen: (chosen: number, days: number, dishes: string) => string;
    /** Sin platos elegidos: el menù lo propone ella. */
    menuNone: string;
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
    monthsShort: ["gen", "feb", "mar", "apr", "mag", "giu", "lug", "ago", "set", "ott", "nov", "dic"],
    weekdays: ["domenica", "lunedì", "martedì", "mercoledì", "giovedì", "venerdì", "sabato"],
    longDate: (weekday, day, month, year) => `${weekday} ${day} ${month} ${year}`,
    labels: {
      type: "Tipo",
      weeks: "Settimane",
      people: "Persone",
      days: "Giorni",
      daysPerWeek: "Giorni a settimana",
      meals: "Pasti",
      date: "Giorno preferito",
      nextDates: "Settimane successive",
      slot: "Fascia oraria",
      service: "Servizio",
      weeklyService: "Servizio a settimana",
      serviceWeeks: (weeks) => `Servizio, ${weeks} settimane`,
      savings: "Risparmio",
      reference: "Riferimento",
    },
    savingsValue: (savings, regular) => `${savings} rispetto a ${regular} a settimana`,
    noDate: "Nessuna preferenza",
    estimateTitle: "Preventivo stimato",
    estimateNote: "Questa è una stima.",
    client: {
      subject: (brand) => `${brand}: abbiamo ricevuto la tua richiesta`,
      preheader: (chef) => `${chef} ti contatterà al più presto.`,
      greeting: (first) => (first ? `Grazie, ${first}!` : "Grazie!"),
      intro: (chef) =>
        `Abbiamo ricevuto la tua richiesta. ${chef} ti contatterà al più presto per confermare giorni, orari, menù e prezzo finale.`,
      noAutoPrice: {
        people: (chef, maxPeople) => `Per più di ${maxPeople} persone il preventivo per il servizio te lo prepara ${chef}.`,
        extra: (chef) => `Per eventi e sessioni extra il preventivo per il servizio te lo prepara ${chef}.`,
      },
      shopping: (chef) => `La spesa la fai tu, con la lista che ti manda ${chef}.`,
      summaryTitle: "La tua richiesta",
      menuChosen: "Piatti scelti",
      menuConfirm: (chef, complete) =>
        complete ? `${chef} ti conferma il menù.` : `${chef} ti conferma il menù e propone i piatti per gli altri giorni.`,
      allergiesNone: "Hai confermato che nessuno ha allergie, intolleranze alimentari o celiachia.",
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
      noAutoPrice: {
        people: (maxPeople) => `Più di ${maxPeople} persone: senza prezzo automatico, prepara tu il preventivo.`,
        extra: () => "Evento o sessione extra: senza prezzo automatico, prepara tu il preventivo.",
      },
      allergies: {
        none: "Ha confermato che nessuno ha allergie, intolleranze o celiachia.",
        listed: "Ha indicato restrizioni alimentari: le trovi nell'app.",
        unknown: "Nessun dato sulle allergie: chiedi al cliente prima di preparare il menù.",
      },
      menuChosen: (chosen, days, dishes) => `Menù scelto dal cliente (${chosen} di ${days} ${days === 1 ? "giorno" : "giorni"}): ${dishes}`,
      menuNone: "Senza menù: lo proponi tu.",
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
    monthsShort: ["ene", "feb", "mar", "abr", "may", "jun", "jul", "ago", "sept", "oct", "nov", "dic"],
    weekdays: ["domingo", "lunes", "martes", "miércoles", "jueves", "viernes", "sábado"],
    longDate: (weekday, day, month, year) => `${weekday}, ${day} de ${month} de ${year}`,
    labels: {
      type: "Tipo",
      weeks: "Semanas",
      people: "Personas",
      days: "Días",
      daysPerWeek: "Días por semana",
      meals: "Comidas",
      date: "Día preferido",
      nextDates: "Semanas siguientes",
      slot: "Franja horaria",
      service: "Servicio",
      weeklyService: "Servicio por semana",
      serviceWeeks: (weeks) => `Servicio, ${weeks} semanas`,
      savings: "Ahorro",
      reference: "Referencia",
    },
    savingsValue: (savings, regular) => `${savings} frente a ${regular} por semana`,
    noDate: "Sin preferencia",
    estimateTitle: "Presupuesto estimado",
    estimateNote: "Esto es una estimación.",
    client: {
      subject: (brand) => `${brand}: hemos recibido tu solicitud`,
      preheader: (chef) => `${chef} te contactará lo antes posible.`,
      greeting: (first) => (first ? `¡Gracias, ${first}!` : "¡Gracias!"),
      intro: (chef) =>
        `Hemos recibido tu solicitud. ${chef} te contactará lo antes posible para confirmar los días, los horarios, el menú y el precio final.`,
      noAutoPrice: {
        people: (chef, maxPeople) => `Para más de ${maxPeople} personas, el presupuesto del servicio te lo prepara ${chef}.`,
        extra: (chef) => `Para eventos y sesiones extra, el presupuesto del servicio te lo prepara ${chef}.`,
      },
      shopping: (chef) => `La compra la haces tú, con la lista que te manda ${chef}.`,
      summaryTitle: "Tu solicitud",
      menuChosen: "Platos elegidos",
      menuConfirm: (chef, complete) =>
        complete ? `${chef} te confirma el menú.` : `${chef} te confirma el menú y propone los platos de los otros días.`,
      allergiesNone: "Confirmaste que nadie tiene alergias, intolerancias alimentarias ni celiaquía.",
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
      noAutoPrice: {
        people: (maxPeople) => `Más de ${maxPeople} personas: sin precio automático, prepara tú el presupuesto.`,
        extra: () => "Evento o sesión extra: sin precio automático, prepara tú el presupuesto.",
      },
      allergies: {
        none: "Confirmó que nadie tiene alergias, intolerancias ni celiaquía.",
        listed: "Indicó restricciones alimentarias: las ves en la app.",
        unknown: "Sin datos de alergias: pregúntale al cliente antes de preparar el menú.",
      },
      menuChosen: (chosen, days, dishes) => `Menú elegido por el cliente (${chosen} de ${days} ${days === 1 ? "día" : "días"}): ${dishes}`,
      menuNone: "Sin menú: lo propones tú.",
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
    monthsShort: ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sept", "Oct", "Nov", "Dec"],
    weekdays: ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"],
    longDate: (weekday, day, month, year) => `${weekday} ${day} ${month} ${year}`,
    labels: {
      type: "Type",
      weeks: "Weeks",
      people: "People",
      days: "Days",
      daysPerWeek: "Days per week",
      meals: "Meals",
      date: "Preferred day",
      nextDates: "Following weeks",
      slot: "Time of day",
      service: "Service",
      weeklyService: "Service per week",
      serviceWeeks: (weeks) => `Service, ${weeks} weeks`,
      savings: "Saving",
      reference: "Reference",
    },
    savingsValue: (savings, regular) => `${savings} compared with ${regular} a week`,
    noDate: "No preference",
    estimateTitle: "Estimated quote",
    estimateNote: "This is an estimate.",
    client: {
      subject: (brand) => `${brand}: we've received your request`,
      preheader: (chef) => `${chef} will contact you as soon as possible.`,
      greeting: (first) => (first ? `Thank you, ${first}!` : "Thank you!"),
      intro: (chef) =>
        `We've received your request. ${chef} will contact you as soon as possible to confirm the days, times, menu and final price.`,
      noAutoPrice: {
        people: (chef, maxPeople) => `For more than ${maxPeople} people, ${chef} will send you a quote for the service.`,
        extra: (chef) => `For events and extra sessions, ${chef} will send you a quote for the service.`,
      },
      shopping: (chef) => `You do the shopping, with the list ${chef} sends you.`,
      summaryTitle: "Your request",
      menuChosen: "Dishes chosen",
      menuConfirm: (chef, complete) =>
        complete ? `${chef} will confirm the menu.` : `${chef} will confirm the menu and suggest dishes for the other days.`,
      allergiesNone: "You confirmed that nobody has any food allergies, intolerances or coeliac disease.",
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
      noAutoPrice: {
        people: (maxPeople) => `More than ${maxPeople} people: no automatic price, prepare the quote yourself.`,
        extra: () => "Event or extra session: no automatic price, prepare the quote yourself.",
      },
      allergies: {
        none: "They confirmed that nobody has any allergies, intolerances or coeliac disease.",
        listed: "They mentioned dietary restrictions: see them in the app.",
        unknown: "No allergy information: ask the client before planning the menu.",
      },
      menuChosen: (chosen, days, dishes) => `Menu chosen by the client (${chosen} of ${days} ${days === 1 ? "day" : "days"}): ${dishes}`,
      menuNone: "No menu chosen: you suggest one.",
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

/**
 * Fecha corta, como en la web y en la app: "2026-11-30" → "30 nov" / "30 nov" / "30 Nov"; con el año si no
 * es `sameYear` ("4 gen 2027").
 */
export function formatDayMonth(iso: string, locale: Locale, sameYear: number): string {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(iso);
  if (!match) return iso;
  const year = Number(match[1]);
  const month = MESSAGES[locale].monthsShort[Number(match[2]) - 1] ?? "";
  return `${Number(match[3])} ${month}${year === sameYear ? "" : ` ${year}`}`;
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
export interface Row {
  label: string;
  value: string;
  valueHtml?: string;
}

export type Block =
  | { kind: "paragraph"; text: string }
  | { kind: "title"; text: string }
  | { kind: "rows"; rows: Row[] }
  | { kind: "note"; text: string }
  | { kind: "button"; label: string; href: string }
  | { kind: "link"; label: string; href: string };

export interface EmailDocument {
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

export function render(doc: EmailDocument): RenderedEmail {
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
  const rows: Row[] = [{ label: messages.labels.type, value: messages.types[summary.type] }];
  // Las semanas son del pedido semanal: una sesión extra es una sola.
  if (summary.type === "week") rows.push({ label: messages.labels.weeks, value: String(summary.weeks) });
  rows.push(
    { label: messages.labels.people, value: formatPeople(summary.adults, summary.kids, locale) },
    { label: summary.type === "week" ? messages.labels.daysPerWeek : messages.labels.days, value: String(summary.days) },
    { label: messages.labels.meals, value: meals },
    { label: messages.labels.date, value: summary.preferredDate ? formatDateLong(summary.preferredDate, locale) : messages.noDate },
  );
  // Una sesión por semana, el mismo día: las fechas de las semanas siguientes (Evelyn las confirma). Cortas
  // y con «·» entre ellas; en el HTML, con espacios duros dentro de cada una y antes del «·» (como la web y
  // la app): en el teléfono el renglón se corta después de un «·», nunca en medio de una fecha.
  if (summary.preferredDate && summary.weeks > 1) {
    const [first, ...next] = weeklyDates(summary.preferredDate, summary.weeks);
    const year = Number(first?.slice(0, 4));
    const dates = next.map((date) => formatDayMonth(date, locale, year));
    rows.push({
      label: messages.labels.nextDates,
      value: dates.join(" · "),
      valueHtml: dates.map((date) => escapeHtml(date).replace(/ /g, "&nbsp;")).join("&nbsp;· "),
    });
  }
  // La web ya no pregunta la franja (manda "any"): solo se muestra si el pedido trae mañana o tarde.
  if (summary.slot !== "any") rows.push({ label: messages.labels.slot, value: messages.slots[summary.slot] });
  return rows;
}

/** Los nombres de los platos en el idioma del email (o en italiano), separados por «·». */
function menuNames(menu: readonly MenuChoice[], locale: Locale): string {
  return menu.map((dish) => localizedText(dish.name, locale)).join(" · ");
}

/** Fila con el importe destacado (el servicio que se paga). */
function strongRow(label: string, cents: number, locale: Locale): Row {
  const value = formatCents(cents, locale);
  return { label, value, valueHtml: `<strong>${escapeHtml(value)}</strong>` };
}

/**
 * El precio: con precio automático, el servicio (por semana y de todas las semanas, y el ahorro si hay
 * descuento); sin él, `noPrice` dice quién prepara el precio. Ninguna fila de compra: la hace el cliente.
 * `note` va debajo (si está vacía, no va).
 */
function estimateBlocks(summary: RequestSummary, messages: Messages, locale: Locale, noPrice: string, note: string): Block[] {
  const { estimate } = summary;
  const money = (cents: number): string => formatCents(cents, locale);
  const blocks: Block[] = [{ kind: "title", text: messages.estimateTitle }];
  if (estimate.autoPrice) {
    const rows: Row[] = [];
    if (summary.weeks > 1) {
      rows.push({ label: messages.labels.weeklyService, value: money(estimate.weeklyServiceCents) });
      rows.push(strongRow(messages.labels.serviceWeeks(summary.weeks), estimate.serviceCents, locale));
    } else {
      rows.push(strongRow(messages.labels.service, estimate.serviceCents, locale));
    }
    if (estimate.savingsCents > 0) {
      rows.push({ label: messages.labels.savings, value: messages.savingsValue(money(estimate.savingsCents), money(estimate.regularWeeklyCents)) });
    }
    blocks.push({ kind: "rows", rows });
  } else {
    blocks.push({ kind: "paragraph", text: noPrice });
  }
  if (note) blocks.push({ kind: "note", text: note });
  return blocks;
}

/** Confirmación al cliente, en su idioma. */
export function renderClientConfirmation(input: ClientConfirmationInput, locale: Locale): RenderedEmail {
  const messages = MESSAGES[locale];
  const { summary } = input;
  const privacyUrl = safeHttpUrl(input.privacyUrl);
  const rows = summaryRows(summary, messages, locale);
  // Los platos que eligió: los nombres de las recetas, nunca sus alérgenos. Sin platos no se dice nada (el
  // intro ya dice que la cocinera le confirma el menù).
  if (summary.menu.length > 0) rows.push({ label: messages.client.menuChosen, value: menuNames(summary.menu, locale) });
  const blocks: Block[] = [
    { kind: "paragraph", text: messages.client.intro(input.chefName) },
    { kind: "title", text: messages.client.summaryTitle },
    { kind: "rows", rows },
  ];
  if (summary.menu.length > 0) {
    blocks.push({ kind: "note", text: messages.client.menuConfirm(input.chefName, summary.menu.length >= summary.days) });
  }
  // De las alergias, solo "nadie tiene", para que vea si se equivocó. "Hay alergias" no sale hacia una
  // dirección que nadie verificó (es un dato de salud); sin respuesta, tampoco se dice nada.
  if (summary.allergies === "none") blocks.push({ kind: "note", text: messages.client.allergiesNone });
  const noPrice = summary.estimate.autoPrice
    ? ""
    : messages.client.noAutoPrice[summary.estimate.reason](input.chefName, summary.estimate.maxPeople);
  // Con precio, que es una estimación; siempre, que la compra la hace él con la lista de la cocinera.
  const shopping = messages.client.shopping(input.chefName);
  const note = summary.estimate.autoPrice ? `${messages.estimateNote} ${shopping}` : shopping;
  blocks.push(...estimateBlocks(summary, messages, locale, noPrice, note));
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
    // El menù que eligió el cliente (cuáles y de cuántos días), o que lo propone ella.
    summary.menu.length > 0
      ? { kind: "paragraph", text: messages.chef.menuChosen(summary.menu.length, summary.days, menuNames(summary.menu, locale)) }
      : { kind: "note", text: messages.chef.menuNone },
    { kind: "note", text: messages.chef.allergies[summary.allergies] },
  ];
  if (input.hasNotes) blocks.push({ kind: "note", text: messages.chef.notes });
  const noPrice = summary.estimate.autoPrice ? "" : messages.chef.noAutoPrice[summary.estimate.reason](summary.estimate.maxPeople);
  // A Evelyn, nada de compra: con precio, solo que es una estimación.
  blocks.push(...estimateBlocks(summary, messages, locale, noPrice, summary.estimate.autoPrice ? messages.estimateNote : ""));
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
