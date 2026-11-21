// Avisos a Evelyn de lo que contesta la clienta en su link (SPEC 5.8, docs/contracts/client-link.md §6):
// confirmó el menú de una semana o pidió cambios. Van a CHEF_NOTIFY_EMAIL, en CHEF_LOCALE, con el diseño de los
// otros emails (_shared/emails.ts) y un botón al pedido en la bandeja (INBOX_URL).
// - El mensaje de la clienta no va: es una nota libre, y las notas libres nunca salen por email (SPEC §6),
//   aunque el aviso vaya a la dirección de Evelyn. Ella lo lee en la app, en el pedido.
// - Del nombre de la clienta, en el asunto (se ve en las notificaciones del celular) solo el de pila, y solo si
//   parece un nombre (safeFirstName); en el cuerpo, el de su ficha, escapado.
// - Nunca el token ni el link de la clienta, alergias, dirección ni nada de pagos.
// Solo sintaxis borrable: corre en Node (tests) y Deno (Edge Functions).
import {
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
  /** El nombre de la ficha de la clienta; null o vacío: «la clienta». */
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
  /** Sin nombre en la ficha. */
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
