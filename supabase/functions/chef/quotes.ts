// Presupuesto (POST /chef/quotes, /chef/quotes/price y /chef/quotes/withdraw, contrato docs/contracts/chef-api.md
// §14; SPEC 5.8): las partes puras que usa handler.ts, con sus tests en quotes.test.ts (Node). La lectura de lo que
// devuelven las funciones SQL chef_create_quote, chef_update_quote y chef_withdraw_quote (migración
// 20261121120000_quotes.sql) y de los términos de un presupuesto (private.quote_terms, que también trae
// chef_menu_send_context en quote.terms). Una respuesta con otra forma es null: un 500, nunca un dato a medias.
// Solo sintaxis borrable: corre en Node (tests) y Deno (Edge Functions).
import {
  MAX_CENTS,
  MAX_COOK_MINUTES,
  MAX_WEEKS,
  QUOTE_WEEK_STATUSES,
  isTimeOfDay,
  type CreateQuoteResponse,
  type QuoteDraftWeek,
  type QuoteTerms,
  type QuoteTermsWeek,
  type WithdrawQuoteResponse,
} from "../_shared/chef_api.ts";
import { isIsoDate, isOneOf } from "../_shared/public_request.ts";

const DB_UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const DB_TIME = /^([01]\d|2[0-3]):([0-5]\d)(?::[0-5]\d(?:\.\d+)?)?$/;
const TIMESTAMP = /^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}/;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isDbUuid(value: unknown): value is string {
  return typeof value === "string" && DB_UUID.test(value);
}

function isIntBetween(value: unknown, min: number, max: number): value is number {
  return typeof value === "number" && Number.isInteger(value) && value >= min && value <= max;
}

function isTimestamp(value: unknown): value is string {
  return typeof value === "string" && TIMESTAMP.test(value);
}

/** time de Postgres ("10:00:00") o "HH:MM" → "HH:MM"; null si es null; undefined si no tiene esa forma. */
function timeOf(value: unknown): string | null | undefined {
  if (value === null) return null;
  if (typeof value !== "string") return undefined;
  const match = DB_TIME.exec(value);
  return match ? `${match[1]}:${match[2]}` : undefined;
}

function readTermsWeek(value: unknown): QuoteTermsWeek | null {
  if (!isRecord(value)) return null;
  const { sessionId, date, start, cookMinutes, serviceCents } = value;
  if (!isDbUuid(sessionId) || typeof date !== "string" || !isIsoDate(date) || !isTimeOfDay(start)) return null;
  if (!isIntBetween(cookMinutes, 1, MAX_COOK_MINUTES) || !isIntBetween(serviceCents, 0, MAX_CENTS)) return null;
  return { sessionId, date, start, cookMinutes, serviceCents };
}

/**
 * private.quote_terms → {quoteId, totalCents, weeks}, o null si no tiene esa forma. Las semanas son las vivas del
 * presupuesto, por fecha y hora (de 0 a 8: un presupuesto sin semanas vivas da 0); totalCents es su suma.
 */
export function quoteTermsFromRpc(data: unknown): QuoteTerms | null {
  if (!isRecord(data)) return null;
  const { quoteId, totalCents } = data;
  const raw = data["weeks"];
  if (!isDbUuid(quoteId) || !isIntBetween(totalCents, 0, MAX_CENTS) || !Array.isArray(raw) || raw.length > MAX_WEEKS) return null;
  const weeks: QuoteTermsWeek[] = [];
  for (const item of raw) {
    const week = readTermsWeek(item);
    if (!week) return null;
    const previous = weeks[weeks.length - 1];
    if (previous && `${week.date}T${week.start}` < `${previous.date}T${previous.start}`) return null;
    weeks.push(week);
  }
  if (weeks.reduce((sum, week) => sum + week.serviceCents, 0) !== totalCents) return null;
  return { quoteId, totalCents, weeks };
}

function readDraftWeek(value: unknown, dryRun: boolean): QuoteDraftWeek | null {
  if (!isRecord(value)) return null;
  const date = value["date"];
  const start = timeOf(value["start_time"]);
  const suggestedStart = timeOf(value["suggested_start"]);
  const cookMinutes = value["cook_minutes"];
  const status = value["status"];
  const serviceCents = value["service_cents"];
  const sessionId = value["session_id"];
  if (typeof date !== "string" || !isIsoDate(date) || start === undefined || suggestedStart === undefined) return null;
  if (!isIntBetween(cookMinutes, 1, MAX_COOK_MINUTES) || !isIntBetween(serviceCents, 0, MAX_CENTS) || !isOneOf(QUOTE_WEEK_STATUSES, status)) return null;
  // En el dryRun, sin sesión y con el estado de la fecha; creado, cada semana con su sesión y su hora (free).
  if (dryRun ? sessionId !== null || status === "free" : !isDbUuid(sessionId) || status !== "free" || start === null) return null;
  return { date, start, cookMinutes, status, suggestedStart, serviceCents, sessionId: dryRun ? null : (sessionId as string) };
}

/**
 * chef_create_quote → la respuesta de POST /quotes (camelCase, horas "HH:MM"), o null si no tiene esa forma. En el
 * dryRun no hay presupuesto, plazo ni sesiones; creado, los tres.
 */
export function createQuoteResponseFromRpc(data: unknown): CreateQuoteResponse | null {
  if (!isRecord(data)) return null;
  const dryRun = data["dry_run"];
  const quoteId = data["quote_id"];
  const requestId = data["request_id"];
  const clientId = data["client_id"];
  const holdUntil = data["hold_until"];
  const raw = data["weeks"];
  if (typeof dryRun !== "boolean" || !isDbUuid(requestId) || (clientId !== null && !isDbUuid(clientId))) return null;
  if (!Array.isArray(raw) || raw.length < 1 || raw.length > MAX_WEEKS) return null;
  if (dryRun ? quoteId !== null || holdUntil !== null : !isDbUuid(quoteId) || !isTimestamp(holdUntil)) return null;
  const weeks: QuoteDraftWeek[] = [];
  for (const item of raw) {
    const week = readDraftWeek(item, dryRun);
    if (!week) return null;
    weeks.push(week);
  }
  return {
    dryRun,
    quoteId: dryRun ? null : (quoteId as string),
    requestId,
    clientId: clientId as string | null,
    holdUntil: dryRun ? null : (holdUntil as string),
    weeks,
  };
}

/** chef_withdraw_quote ({quote_id, request_id, already, cancelled}) → camelCase, o null si no tiene esa forma. */
export function withdrawQuoteResponseFromRpc(data: unknown): WithdrawQuoteResponse | null {
  if (!isRecord(data)) return null;
  const quoteId = data["quote_id"];
  const requestId = data["request_id"];
  const already = data["already"];
  const cancelled = data["cancelled"];
  if (!isDbUuid(quoteId) || !isDbUuid(requestId) || typeof already !== "boolean" || !isIntBetween(cancelled, 0, MAX_WEEKS)) return null;
  return { quoteId, requestId, already, cancelled };
}
