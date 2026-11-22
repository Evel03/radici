// Avisos a Evelyn de lo que contesta la clienta en su link (SPEC 5.8, docs/contracts/client-link.md §6):
// confirmó el menú de una semana o pidió cambios, o aceptó o rechazó el presupuesto. Van a CHEF_NOTIFY_EMAIL, en
// CHEF_LOCALE, con el diseño de los otros emails (_shared/emails.ts) y un botón al pedido en la bandeja (INBOX_URL).
// - El mensaje de la clienta no va: es una nota libre, y las notas libres nunca salen por email (SPEC §6),
//   aunque el aviso vaya a la dirección de Evelyn. Ella lo lee en la app, en el pedido.
// - El nombre de la clienta es el que llegó con el pedido (o, si no tiene, el de la ficha): el mismo del mensaje y
//   de la bandeja. En el asunto (se ve en las notificaciones del celular) solo el de pila, y solo si parece un
//   nombre (safeFirstName); en el cuerpo, entero y escapado.
// - Del presupuesto aceptado, las semanas y el precio del servicio que aceptó (es de Evelyn); nunca nada de pagos.
// - Nunca el token ni el link de la clienta, alergias ni dirección.
// Solo sintaxis borrable: corre en Node (tests) y Deno (Edge Functions).
import {
  formatCents,
  formatDateLong,
  inboxRequestUrl,
  render as renderEmailDocument,
  safeFirstName,
  safeHttpUrl,
  type Block,
  type RenderedEmail,
} from "./emails.ts";
import type { Locale } from "./public_request.ts";

/** Qué contestó la clienta: confirmó el menú o pidió cambios. */
export type MenuAnswerKind = "confirmed" | "changes";

export interface MenuAnswerNotice {
  kind: MenuAnswerKind;
  brand: string;
  /** El nombre de la clienta (el del pedido o el de la ficha); null o vacío: «la clienta». */
  clientName: string | null;
  requestId: string;
  /** «Semana k de N», la fecha ("AAAA-MM-DD") y la hora de llegada ("HH:MM") de esa semana. */
  week: number;
  weeks: number;
  date: string;
  start: string;
  /** Bandeja de la app web; el botón abre el pedido. */
  inboxUrl: string | null;
}

interface AnswerMessages {
  subject: (first: string, week: number) => string;
  preheader: string;
  heading: string;
  intro: (name: string, week: number, weeks: number, date: string, start: string) => string;
  /** Debajo del párrafo, o "" si no va nada. */
  note: string;
}

interface Messages {
  /** Sin nombre. */
  someone: string;
  confirmed: AnswerMessages;
  changes: AnswerMessages;
  button: string;
  footer: (brand: string) => string;
}

const MESSAGES: Readonly<Record<Locale, Messages>> = {
  it: {
    someone: "La cliente",
    confirmed: {
      subject: (first, week) => (first ? `${first} ha confermato il menù della settimana ${week}` : `Menù della settimana ${week} confermato`),
      preheader: "Lo trovi confermato nella richiesta.",
      heading: "Menù confermato",
      intro: (name, week, weeks, date, start) =>
        `${name} ha confermato il menù della settimana ${week} di ${weeks} (${date}, arrivo alle ${start}).`,
      note: "",
    },
    changes: {
      subject: (first, week) =>
        first ? `${first} chiede dei cambi al menù della settimana ${week}` : `Cambi richiesti al menù della settimana ${week}`,
      preheader: "Leggi il suo messaggio nell'app.",
      heading: "Cambi al menù",
      intro: (name, week, weeks, date, start) =>
        `${name} ha chiesto dei cambi al menù della settimana ${week} di ${weeks} (${date}, arrivo alle ${start}).`,
      note: "Il suo messaggio lo trovi nell'app, nella richiesta: sistema il menù e rimandaglielo.",
    },
    button: "Apri la richiesta",
    footer: (brand) => `Avviso automatico di ${brand}.`,
  },
  es: {
    someone: "La clienta",
    confirmed: {
      subject: (first, week) => (first ? `${first} confirmó el menú de la semana ${week}` : `Menú de la semana ${week} confirmado`),
      preheader: "Lo ves confirmado en el pedido.",
      heading: "Menú confirmado",
      intro: (name, week, weeks, date, start) =>
        `${name} confirmó el menú de la semana ${week} de ${weeks} (${date}, llegada a las ${start}).`,
      note: "",
    },
    changes: {
      subject: (first, week) =>
        first ? `${first} pidió cambios en el menú de la semana ${week}` : `Cambios pedidos en el menú de la semana ${week}`,
      preheader: "Lee su mensaje en la app.",
      heading: "Cambios en el menú",
      intro: (name, week, weeks, date, start) =>
        `${name} pidió cambios en el menú de la semana ${week} de ${weeks} (${date}, llegada a las ${start}).`,
      note: "Su mensaje está en la app, en el pedido: cambia el menú y vuelve a enviárselo.",
    },
    button: "Abrir en la bandeja",
    footer: (brand) => `Aviso automático de ${brand}.`,
  },
  en: {
    someone: "The client",
    confirmed: {
      subject: (first, week) => (first ? `${first} confirmed the menu for week ${week}` : `Menu for week ${week} confirmed`),
      preheader: "You'll see it confirmed in the request.",
      heading: "Menu confirmed",
      intro: (name, week, weeks, date, start) =>
        `${name} confirmed the menu for week ${week} of ${weeks} (${date}, arriving at ${start}).`,
      note: "",
    },
    changes: {
      subject: (first, week) =>
        first ? `${first} asked for changes to the menu for week ${week}` : `Changes requested to the menu for week ${week}`,
      preheader: "Read their message in the app.",
      heading: "Menu changes",
      intro: (name, week, weeks, date, start) =>
        `${name} asked for changes to the menu for week ${week} of ${weeks} (${date}, arriving at ${start}).`,
      note: "Their message is in the app, in the request: update the menu and send it again.",
    },
    button: "Open in the inbox",
    footer: (brand) => `Automatic notice from ${brand}.`,
  },
};

/** Aviso a Evelyn de lo que contestó la clienta, en CHEF_LOCALE. */
export function renderMenuAnswerNotification(input: MenuAnswerNotice, locale: Locale): RenderedEmail {
  const messages = MESSAGES[locale];
  const answer = messages[input.kind];
  const name = input.clientName?.trim() || messages.someone;
  const inboxUrl = safeHttpUrl(input.inboxUrl);
  const blocks: Block[] = [
    { kind: "paragraph", text: answer.intro(name, input.week, input.weeks, formatDateLong(input.date, locale), input.start) },
  ];
  if (answer.note) blocks.push({ kind: "note", text: answer.note });
  if (inboxUrl) blocks.push({ kind: "button", label: messages.button, href: inboxRequestUrl(inboxUrl, input.requestId) });

  return renderEmailDocument({
    locale,
    subject: answer.subject(safeFirstName(input.clientName ?? ""), input.week),
    preheader: answer.preheader,
    brand: input.brand,
    heading: answer.heading,
    blocks,
    slogan: null,
    footer: messages.footer(input.brand),
  });
}

// ---------------------------------------------------------------------------
// El presupuesto: la clienta lo aceptó o lo rechazó
// ---------------------------------------------------------------------------

/** Qué hizo la clienta con el presupuesto. */
export type QuoteAnswerKind = "accepted" | "declined";

export interface QuoteAnswerNotice {
  kind: QuoteAnswerKind;
  brand: string;
  /** El nombre de la clienta (el del pedido o el de la ficha); null o vacío: «la clienta». */
  clientName: string | null;
  requestId: string;
  /** La primera semana del presupuesto (la del envío que lo llevó): fecha ("AAAA-MM-DD") y llegada ("HH:MM"). */
  date: string;
  start: string;
  /** Al aceptar: cuántas semanas y el precio del servicio de todas (centavos). Al rechazar, null. */
  weeks: number | null;
  totalCents: number | null;
  inboxUrl: string | null;
}

interface QuoteAnswerMessages {
  subject: (first: string) => string;
  preheader: string;
  heading: string;
  /** Al aceptar: weeks y total ya escritos («4 semanas», «560,00 €»). Al rechazar no van. */
  intro: (name: string, weeks: string, total: string) => string;
  /** La primera semana (date: la fecha larga). */
  first: (date: string, start: string) => string;
  note: string;
}

interface QuoteMessages {
  someone: string;
  weeks: (n: number) => string;
  accepted: QuoteAnswerMessages;
  declined: QuoteAnswerMessages;
  button: string;
  footer: (brand: string) => string;
}

const QUOTE_MESSAGES: Readonly<Record<Locale, QuoteMessages>> = {
  it: {
    someone: "La cliente",
    weeks: (n) => (n === 1 ? "1 settimana" : `${n} settimane`),
    accepted: {
      subject: (first) => (first ? `${first} ha accettato il preventivo` : "Preventivo accettato"),
      preheader: "Le settimane sono confermate in agenda.",
      heading: "Preventivo accettato",
      intro: (name, weeks, total) => `${name} ha accettato il preventivo: ${weeks}, ${total}.`,
      first: (date, start) => `La prima settimana è ${date}, con arrivo alle ${start}.`,
      note: "Le settimane sono confermate in agenda, e anche il menù della settimana 1.",
    },
    declined: {
      subject: (first) => (first ? `${first} ha rifiutato il preventivo` : "Preventivo rifiutato"),
      preheader: "Le settimane proposte sono di nuovo libere.",
      heading: "Preventivo rifiutato",
      intro: (name) => `${name} ha rifiutato il preventivo.`,
      first: (date, start) => `La prima settimana proposta era ${date}, con arrivo alle ${start}.`,
      note: "Le settimane proposte sono di nuovo libere in agenda.",
    },
    button: "Apri la richiesta",
    footer: (brand) => `Avviso automatico di ${brand}.`,
  },
  es: {
    someone: "La clienta",
    weeks: (n) => (n === 1 ? "1 semana" : `${n} semanas`),
    accepted: {
      subject: (first) => (first ? `${first} aceptó el presupuesto` : "Presupuesto aceptado"),
      preheader: "Las semanas quedaron confirmadas en la agenda.",
      heading: "Presupuesto aceptado",
      intro: (name, weeks, total) => `${name} aceptó el presupuesto: ${weeks}, ${total}.`,
      first: (date, start) => `La primera semana es el ${date}, con llegada a las ${start}.`,
      note: "Las semanas quedaron confirmadas en la agenda, y el menú de la semana 1 también.",
    },
    declined: {
      subject: (first) => (first ? `${first} rechazó el presupuesto` : "Presupuesto rechazado"),
      preheader: "Las semanas propuestas quedaron libres.",
      heading: "Presupuesto rechazado",
      intro: (name) => `${name} rechazó el presupuesto.`,
      first: (date, start) => `La primera semana propuesta era el ${date}, con llegada a las ${start}.`,
      note: "Las semanas propuestas quedaron libres en la agenda.",
    },
    button: "Abrir en la bandeja",
    footer: (brand) => `Aviso automático de ${brand}.`,
  },
  en: {
    someone: "The client",
    weeks: (n) => (n === 1 ? "1 week" : `${n} weeks`),
    accepted: {
      subject: (first) => (first ? `${first} accepted the quote` : "Quote accepted"),
      preheader: "The weeks are confirmed in the calendar.",
      heading: "Quote accepted",
      intro: (name, weeks, total) => `${name} accepted the quote: ${weeks}, ${total}.`,
      first: (date, start) => `The first week is on ${date}, arriving at ${start}.`,
      note: "The weeks are confirmed in the calendar, and so is the menu for week 1.",
    },
    declined: {
      subject: (first) => (first ? `${first} declined the quote` : "Quote declined"),
      preheader: "The proposed weeks are free again.",
      heading: "Quote declined",
      intro: (name) => `${name} declined the quote.`,
      first: (date, start) => `The first proposed week was on ${date}, arriving at ${start}.`,
      note: "The proposed weeks are free again in the calendar.",
    },
    button: "Open in the inbox",
    footer: (brand) => `Automatic notice from ${brand}.`,
  },
};

/**
 * Aviso a Evelyn de que la clienta aceptó (con las semanas y el precio del servicio) o rechazó el presupuesto, en
 * CHEF_LOCALE. Sin texto libre: ni aceptar ni rechazar llevan un mensaje.
 */
export function renderQuoteAnswerNotification(input: QuoteAnswerNotice, locale: Locale): RenderedEmail {
  const messages = QUOTE_MESSAGES[locale];
  const answer = messages[input.kind];
  const name = input.clientName?.trim() || messages.someone;
  const inboxUrl = safeHttpUrl(input.inboxUrl);
  const weeks = input.weeks === null ? "" : messages.weeks(input.weeks);
  const total = input.totalCents === null ? "" : formatCents(input.totalCents, locale);
  const blocks: Block[] = [
    { kind: "paragraph", text: answer.intro(name, weeks, total) },
    { kind: "paragraph", text: answer.first(formatDateLong(input.date, locale), input.start) },
    { kind: "note", text: answer.note },
  ];
  if (inboxUrl) blocks.push({ kind: "button", label: messages.button, href: inboxRequestUrl(inboxUrl, input.requestId) });

  return renderEmailDocument({
    locale,
    subject: answer.subject(safeFirstName(input.clientName ?? "")),
    preheader: answer.preheader,
    brand: input.brand,
    heading: answer.heading,
    blocks,
    slogan: null,
    footer: messages.footer(input.brand),
  });
}
