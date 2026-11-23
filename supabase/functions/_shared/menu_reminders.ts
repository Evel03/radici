// Avisos a Evelyn para completar el menú de cada semana (SPEC 5.8; migración
// 20261121110000_menu_reminders.sql). Lee lo que devuelve public.menu_reminders_due y arma el email: uno
// por turno, con todas las semanas que tocan. Nunca lleva alergias ni direcciones: solo el nombre de la
// clienta (el email va a la cocinera), la semana, la fecha y el límite.
// Solo sintaxis borrable: corre en Node (tests) y Deno (Edge Functions).
import { formatDateLong, inboxRequestUrl, render, type Block, type RenderedEmail } from "./emails.ts";
import { isIsoDate, isUuid, type Locale } from "./public_request.ts";

export const REMINDER_KINDS = ["first", "last", "overdue"] as const;
export type ReminderKind = (typeof REMINDER_KINDS)[number];

/** Una semana con un aviso que toca, tal como la devuelve menu_reminders_due. */
export interface DueReminder {
  sessionId: string;
  requestId: string;
  kind: ReminderKind;
  /** Día de la cocina (AAAA-MM-DD, en Roma) y hora de llegada (HH:MM). */
  date: string;
  start: string;
  /** El límite para mandar el menú: 48 h antes de la llegada (timestamptz en ISO). */
  deadline: string;
  week: number;
  weeks: number;
  clientName: string;
  changesRequested: boolean;
}

const TIME = /^([01]\d|2[0-3]):[0-5]\d$/;

function isReminderKind(value: unknown): value is ReminderKind {
  return typeof value === "string" && (REMINDER_KINDS as readonly string[]).includes(value);
}

function positiveInt(value: unknown): value is number {
  return typeof value === "number" && Number.isInteger(value) && value >= 1 && value <= 52;
}

/** El jsonb de menu_reminders_due → avisos validados, o null si algo no tiene la forma esperada. */
export function dueRemindersFromRpc(data: unknown): DueReminder[] | null {
  if (!Array.isArray(data)) return null;
  const out: DueReminder[] = [];
  for (const item of data) {
    if (typeof item !== "object" || item === null) return null;
    const row = item as Record<string, unknown>;
    const { sessionId, requestId, kind, date, start, deadline, week, weeks, clientName, changesRequested } = row;
    if (
      typeof sessionId !== "string" || !isUuid(sessionId) ||
      typeof requestId !== "string" || !isUuid(requestId) ||
      !isReminderKind(kind) ||
      typeof date !== "string" || !isIsoDate(date) ||
      typeof start !== "string" || !TIME.test(start) ||
      typeof deadline !== "string" || Number.isNaN(Date.parse(deadline)) ||
      !positiveInt(week) || !positiveInt(weeks) || week > weeks ||
      typeof clientName !== "string" ||
      typeof changesRequested !== "boolean"
    ) {
      return null;
    }
    out.push({
      sessionId: sessionId.toLowerCase(),
      requestId: requestId.toLowerCase(),
      kind,
      date,
      start,
      deadline,
      week,
      weeks,
      clientName: clientName.trim(),
      changesRequested,
    });
  }
  return out;
}

/** Un instante en Roma: {date: AAAA-MM-DD, time: HH:MM}. */
export function romeDateTime(iso: string): { date: string; time: string } {
  const parts = new Intl.DateTimeFormat("en-GB", {
    timeZone: "Europe/Rome",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    hourCycle: "h23",
  }).formatToParts(new Date(iso));
  const get = (type: string): string => parts.find((part) => part.type === type)?.value ?? "";
  return { date: `${get("year")}-${get("month")}-${get("day")}`, time: `${get("hour")}:${get("minute")}` };
}

interface ReminderMessages {
  subjectOne: (urgent: boolean, name: string) => string;
  subjectMany: (urgent: boolean, count: number) => string;
  intro: string;
  weekOf: (week: number, weeks: number) => string;
  cooking: string;
  sendBy: string;
  dateTime: (date: string, time: string) => string;
  kind: Readonly<Record<ReminderKind, string>>;
  changesRequested: string;
  open: string;
  footer: string;
}

const MESSAGES: Readonly<Record<Locale, ReminderMessages>> = {
  es: {
    subjectOne: (urgent, name) => (urgent ? `Urgente: manda el menú de ${name}` : `Recordatorio: el menú de ${name}`),
    subjectMany: (urgent, count) => (urgent ? `Urgente: hay ${count} menús sin enviar` : `Recordatorio: ${count} menús por enviar`),
    intro:
      "La clienta tiene que recibir el menú y la lista de compras al menos 48 horas antes de la cocina, para tener tiempo de comprar.",
    weekOf: (week, weeks) => `semana ${week} de ${weeks}`,
    cooking: "Cocina",
    sendBy: "Enviarlo antes del",
    dateTime: (date, time) => `${date}, ${time}`,
    kind: {
      first: "La cocina es en menos de 4 días.",
      last: "El límite vence en menos de 24 horas.",
      overdue: "Ya pasó el límite de 48 horas: mándalo cuanto antes.",
    },
    changesRequested: "La clienta pidió cambios: manda el menú corregido.",
    open: "Abrir el pedido",
    footer: "Este aviso se repite hasta que el menú salga.",
  },
  it: {
    subjectOne: (urgent, name) => (urgent ? `Urgente: invia il menù di ${name}` : `Promemoria: il menù di ${name}`),
    subjectMany: (urgent, count) => (urgent ? `Urgente: ${count} menù non ancora inviati` : `Promemoria: ${count} menù da inviare`),
    intro:
      "La cliente deve ricevere il menù e la lista della spesa almeno 48 ore prima della cucina, per avere il tempo di fare la spesa.",
    weekOf: (week, weeks) => `settimana ${week} di ${weeks}`,
    cooking: "Cucina",
    sendBy: "Da inviare entro",
    dateTime: (date, time) => `${date}, ore ${time}`,
    kind: {
      first: "La cucina è tra meno di 4 giorni.",
      last: "Il termine scade tra meno di 24 ore.",
      overdue: "Il termine di 48 ore è passato: invialo il prima possibile.",
    },
    changesRequested: "La cliente ha chiesto delle modifiche: invia il menù corretto.",
    open: "Apri la richiesta",
    footer: "Questo avviso si ripete finché il menù non parte.",
  },
  en: {
    subjectOne: (urgent, name) => (urgent ? `Urgent: send ${name}'s menu` : `Reminder: ${name}'s menu`),
    subjectMany: (urgent, count) => (urgent ? `Urgent: ${count} menus not sent yet` : `Reminder: ${count} menus to send`),
    intro: "The client must receive the menu and the shopping list at least 48 hours before cooking, so she has time to shop.",
    weekOf: (week, weeks) => `week ${week} of ${weeks}`,
    cooking: "Cooking",
    sendBy: "Send by",
    dateTime: (date, time) => `${date}, ${time}`,
    kind: {
      first: "Cooking is less than 4 days away.",
      last: "The deadline is less than 24 hours away.",
      overdue: "The 48-hour deadline has passed: send it as soon as possible.",
    },
    changesRequested: "The client asked for changes: send the corrected menu.",
    open: "Open the request",
    footer: "This reminder repeats until the menu is sent.",
  },
};

export interface ReminderEmailInput {
  brand: string;
  /** INBOX_URL (/gestione/), o null: sin el link al pedido. */
  inboxUrl: string | null;
}

/** El email de un turno con todas las semanas que tocan (al menos una). */
export function renderMenuReminders(items: readonly DueReminder[], input: ReminderEmailInput, locale: Locale): RenderedEmail {
  const m = MESSAGES[locale];
  const urgent = items.some((item) => item.kind === "overdue");
  const first = items[0];
  const subject =
    items.length === 1 && first ? m.subjectOne(urgent, first.clientName) : m.subjectMany(urgent, items.length);
  const blocks: Block[] = [{ kind: "paragraph", text: m.intro }];
  for (const item of items) {
    const deadline = romeDateTime(item.deadline);
    blocks.push({ kind: "title", text: item.weeks > 1 ? `${item.clientName} · ${m.weekOf(item.week, item.weeks)}` : item.clientName });
    blocks.push({
      kind: "rows",
      rows: [
        { label: m.cooking, value: m.dateTime(formatDateLong(item.date, locale), item.start) },
        { label: m.sendBy, value: m.dateTime(formatDateLong(deadline.date, locale), deadline.time) },
      ],
    });
    if (item.changesRequested) blocks.push({ kind: "note", text: m.changesRequested });
    blocks.push({ kind: "note", text: m.kind[item.kind] });
    if (input.inboxUrl) blocks.push({ kind: "link", label: m.open, href: inboxRequestUrl(input.inboxUrl, item.requestId) });
  }
  return render({
    locale,
    subject: `${input.brand}: ${subject}`,
    preheader: m.intro,
    brand: input.brand,
    heading: subject,
    blocks,
    slogan: null,
    footer: m.footer,
  });
}

/**
 * Clave de idempotencia del email de un turno (Resend la recuerda 24 h): la cocina, el turno de 15
 * minutos y los avisos. Un reintento del mismo turno no duplica el email; el urgente de dos horas
 * después es otro turno.
 */
export async function reminderIdempotencyKey(chefId: string, now: Date, items: readonly DueReminder[]): Promise<string> {
  const slot = Math.floor(now.getTime() / (15 * 60 * 1000));
  const data = new TextEncoder().encode(items.map((item) => `${item.sessionId}:${item.kind}`).join(","));
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", data));
  const hex = Array.from(digest, (byte) => byte.toString(16).padStart(2, "0")).join("");
  return `menu-reminders/${chefId}/${slot}/${hex.slice(0, 32)}`;
}
