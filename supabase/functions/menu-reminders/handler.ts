// Lógica de la Edge Function menu-reminders: los avisos a Evelyn para completar el menú de cada semana
// (SPEC 5.8; migración 20261121110000_menu_reminders.sql). La llama la base cada 15 minutos (pg_cron +
// pg_net, private.call_menu_reminders) con el secreto compartido en la cabecera x-reminders-secret.
// No depende de Deno ni de supabase-js: index.ts arma las dependencias reales y los tests las simulan.
//
// Orden: método (405) → secreto configurado (503) → secreto de la cabecera (401) → cocina (CHEF_ID o la
// única de public.chefs; 500) → menu_reminders_due → nada que avisar (200) → email configurado (503)
// → email a CHEF_NOTIFY_EMAIL (502 si falla: no se marca y el turno siguiente lo reintenta) →
// menu_reminders_mark → 200.
//
// Los logs llevan solo evento, códigos y contadores: nunca nombres, fechas ni emails.
// Solo sintaxis borrable: corre en Node (tests) y Deno (Edge Functions).
import { StoreError, logStoreError, type Logger } from "../_shared/edge.ts";
import { brandFromMailFrom, safeHttpUrl } from "../_shared/emails.ts";
import {
  dueRemindersFromRpc,
  reminderIdempotencyKey,
  renderMenuReminders,
  type DueReminder,
} from "../_shared/menu_reminders.ts";
import { LOCALES, isUuid, type Locale } from "../_shared/public_request.ts";
import type { EmailMessage, SendOutcome } from "../_shared/resend.ts";

export const SECRET_HEADER = "x-reminders-secret";
/** Idioma de los avisos si CHEF_LOCALE falta o no es it, es ni en. */
export const DEFAULT_CHEF_LOCALE: Locale = "es";

export interface RemindersConfig {
  /** MENU_REMINDERS_SECRET: el mismo que el despliegue guarda en Vault. Sin él, 503. */
  secret: string | null;
  /** CHEF_ID en minúsculas, o null: la única fila de public.chefs. */
  chefId: string | null;
  /** Variables con un valor que no sirve (CHEF_ID que no es uuid): 500. */
  invalid: string[];
  chefNotifyEmail: string | null;
  chefLocale: Locale;
  inboxUrl: string | null;
  mailFrom: string | null;
  resendApiKey: string | null;
  emailTransport: "log" | "resend";
}

export function readRemindersConfig(get: (name: string) => string | undefined): RemindersConfig {
  const value = (name: string): string | null => {
    const raw = get(name)?.trim();
    return raw ? raw : null;
  };
  const chefId = value("CHEF_ID")?.toLowerCase() ?? null;
  const locale = value("CHEF_LOCALE")?.toLowerCase();
  return {
    secret: value("MENU_REMINDERS_SECRET"),
    chefId,
    invalid: chefId !== null && !isUuid(chefId) ? ["CHEF_ID"] : [],
    chefNotifyEmail: value("CHEF_NOTIFY_EMAIL"),
    chefLocale: (LOCALES as readonly string[]).includes(locale ?? "") ? (locale as Locale) : DEFAULT_CHEF_LOCALE,
    inboxUrl: safeHttpUrl(value("INBOX_URL")),
    mailFrom: value("MAIL_FROM"),
    resendApiKey: value("RESEND_API_KEY"),
    emailTransport: value("EMAIL_TRANSPORT")?.toLowerCase() === "log" ? "log" : "resend",
  };
}

/** Lo que falta para avisar (solo nombres de variables), para el aviso del arranque. */
export function remindersConfigWarnings(config: RemindersConfig): string[] {
  const warnings: string[] = [];
  if (!config.secret) warnings.push("MENU_REMINDERS_SECRET");
  if (!config.chefNotifyEmail) warnings.push("CHEF_NOTIFY_EMAIL");
  if (config.emailTransport === "resend") {
    if (!config.resendApiKey) warnings.push("RESEND_API_KEY");
    if (!config.mailFrom) warnings.push("MAIL_FROM");
  }
  if (!config.inboxUrl) warnings.push("INBOX_URL");
  return warnings;
}

export type DefaultChef = { ok: true; chefId: string } | { ok: false; reason: "no_chef" | "multiple_chefs" };

export interface RemindersStore {
  /** La única fila de public.chefs (como public-request). */
  resolveDefaultChef(): Promise<DefaultChef>;
  /** public.menu_reminders_due(p_chef_id, p_now): el jsonb tal cual. */
  due(chefId: string, nowIso: string): Promise<unknown>;
  /** public.menu_reminders_mark(p_chef_id, p_items, p_now): cuántos marcó. */
  mark(chefId: string, items: ReadonlyArray<{ sessionId: string; kind: string }>, nowIso: string): Promise<number>;
}

export interface RemindersDeps {
  config: RemindersConfig;
  store: RemindersStore;
  sendEmail: (message: EmailMessage, apiKey: string) => Promise<SendOutcome>;
  log: Logger;
  now: () => Date;
}

const JSON_HEADERS = { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" };

function reply(status: number, body: Record<string, unknown>, extra: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...JSON_HEADERS, ...extra } });
}

/** Comparación de largo y contenido sin cortar en la primera diferencia. */
export function sameSecret(given: string, expected: string): boolean {
  const a = new TextEncoder().encode(given);
  const b = new TextEncoder().encode(expected);
  let diff = a.length ^ b.length;
  for (let i = 0; i < Math.max(a.length, b.length); i++) diff |= (a[i] ?? 0) ^ (b[i] ?? 0);
  return diff === 0;
}

async function chefIdFor(deps: RemindersDeps): Promise<string | null> {
  if (deps.config.chefId) return deps.config.chefId;
  const resolved = await deps.store.resolveDefaultChef();
  if (resolved.ok) return resolved.chefId;
  deps.log("error", "chef_unresolved", { reason: resolved.reason });
  return null;
}

export function createMenuRemindersHandler(deps: RemindersDeps): (request: Request) => Promise<Response> {
  const { config, log } = deps;
  return async (request) => {
    if (request.method !== "POST") return reply(405, { error: "methodNotAllowed" }, { Allow: "POST" });
    if (!config.secret) {
      log("error", "config_missing", { missing: ["MENU_REMINDERS_SECRET"] });
      return reply(503, { error: "notConfigured" });
    }
    const given = request.headers.get(SECRET_HEADER) ?? "";
    if (!sameSecret(given, config.secret)) {
      log("warn", "auth_rejected", { reason: given ? "mismatch" : "missing" });
      return reply(401, { error: "unauthorized" });
    }
    if (config.invalid.length > 0) {
      log("error", "config_invalid", { invalid: config.invalid });
      return reply(500, { error: "serverError" });
    }

    const now = deps.now();
    const nowIso = now.toISOString();
    let items: DueReminder[] | null;
    let chefId: string | null;
    try {
      chefId = await chefIdFor(deps);
      if (!chefId) return reply(500, { error: "serverError" });
      items = dueRemindersFromRpc(await deps.store.due(chefId, nowIso));
    } catch (error) {
      logStoreError(log, error, "due");
      return reply(error instanceof StoreError && error.code === null ? 503 : 500, { error: "serverError" });
    }
    if (items === null) {
      log("error", "unexpected_result", { op: "due" });
      return reply(500, { error: "serverError" });
    }
    if (items.length === 0) return reply(200, { sent: 0 });

    const kinds = { first: 0, last: 0, overdue: 0 };
    for (const item of items) kinds[item.kind] += 1;
    if (!config.chefNotifyEmail || (config.emailTransport === "resend" && (!config.resendApiKey || !config.mailFrom))) {
      log("error", "email_unavailable", { due: items.length });
      return reply(503, { error: "emailUnavailable" });
    }

    const email = renderMenuReminders(items, { brand: brandFromMailFrom(config.mailFrom), inboxUrl: config.inboxUrl }, config.chefLocale);
    if (config.emailTransport === "log") {
      log("info", "email_logged", { due: items.length, htmlChars: email.html.length, textChars: email.text.length });
    } else {
      const message: EmailMessage = {
        from: config.mailFrom as string,
        to: config.chefNotifyEmail,
        replyTo: null,
        subject: email.subject,
        html: email.html,
        text: email.text,
        idempotencyKey: await reminderIdempotencyKey(chefId, now, items),
      };
      const outcome = await deps.sendEmail(message, config.resendApiKey as string);
      if (!outcome.ok) {
        log("error", "email_failed", { due: items.length, status: outcome.status, errorName: outcome.errorName });
        return reply(502, { error: "emailFailed" });
      }
    }

    let marked: number;
    try {
      marked = await deps.store.mark(chefId, items.map((item) => ({ sessionId: item.sessionId, kind: item.kind })), nowIso);
    } catch (error) {
      // El email ya salió: si no se marca, el turno siguiente lo repite (mejor dos avisos que ninguno).
      logStoreError(log, error, "mark");
      return reply(500, { error: "serverError" });
    }
    log("info", "reminders_sent", { first: kinds.first, last: kinds.last, overdue: kinds.overdue, marked });
    return reply(200, { sent: items.length });
  };
}
