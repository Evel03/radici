// El Send Email Hook de Supabase Auth (PR19, contrato docs/contracts/auth.md §16): lo que no depende de Deno.
//
// Cuando el hook está prendido (PR20), GoTrue no manda los emails de Auth: hace un POST firmado a la Edge Function
// auth-email con el usuario y los datos del email, y espera 200 {} (salió) o un error {"error": {"http_code",
// "message"}} que devuelve a quien pidió el email. Docs: https://supabase.com/docs/guides/auth/auth-hooks/send-email-hook
// (leído el 27/11/2026).
//
// - La firma es Standard Webhooks (https://www.standardwebhooks.com/): cabeceras webhook-id, webhook-timestamp y
//   webhook-signature ("v1,<base64>" separadas por espacio); se firma `${id}.${timestamp}.${cuerpo}` con HMAC-SHA256 y
//   el secreto "v1,whsec_<base64>" (la parte después de whsec_, decodificada). Tolerancia: 5 minutos.
// - email_action_type → el tipo de plantilla de auth_emails.ts. «magiclink» y «email» son el código; «signup», la
//   confirmación del alta; «recovery», la contraseña; «email_change», «invite» y «reauthentication» no los usa Radici.
// - El email nunca sale en un log ni llega a la base: la base recibe un HMAC del destinatario (con IP_HASH_SALT).
// Solo sintaxis borrable: corre en Node (tests) y Deno (Edge Functions).
import { accessLink, authEmailTexts, renderAuthEmail, type AuthEmailKind } from "./auth_emails.ts";
import { LOCALES, isUuid, type Locale } from "./public_request.ts";

/** Cuánto puede tener la firma (en segundos, para los dos lados): la de Standard Webhooks. */
export const WEBHOOK_TOLERANCE_SECONDS = 5 * 60;
/** Tope del cuerpo del pedido de GoTrue (trae el usuario con sus identidades). */
export const HOOK_MAX_BODY_BYTES = 64 * 1024;
/** Idioma del email si la cuenta no tiene uno válido. */
export const DEFAULT_AUTH_LOCALE: Locale = "it";

/** email_action_type de GoTrue → la plantilla. Lo que no está acá se rechaza. */
export const ACTION_KINDS: Readonly<Record<string, AuthEmailKind>> = {
  magiclink: "magic_link",
  email: "magic_link",
  signup: "confirmation",
  recovery: "recovery",
  email_change: "email_change",
  invite: "invite",
  reauthentication: "reauthentication",
};

export interface WebhookHeaders {
  id: string | null;
  timestamp: string | null;
  signature: string | null;
}

export type WebhookCheck = { ok: true } | { ok: false; reason: "no_secret" | "missing_headers" | "stale" | "bad_signature" };

function base64ToBytes(value: string): Uint8Array | null {
  try {
    const binary = atob(value);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    return bytes;
  } catch {
    return null;
  }
}

function bytesToBase64(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

/**
 * Los secretos del hook (SEND_EMAIL_HOOK_SECRETS): uno o más "v1,whsec_<base64>" separados por «|» o espacios (para
 * cambiarlo sin cortar: el viejo y el nuevo a la vez). Devuelve las claves ya decodificadas; ignora lo que no tiene
 * esa forma.
 */
export function parseHookSecrets(raw: string | null | undefined): Uint8Array[] {
  const keys: Uint8Array[] = [];
  for (const part of (raw ?? "").split(/[|\s]+/)) {
    const match = /^v1,whsec_([A-Za-z0-9+/=]+)$/.exec(part);
    const key = match?.[1] ? base64ToBytes(match[1]) : null;
    if (key && key.length >= 16) keys.push(key);
  }
  return keys;
}

/** Comparación de largo fijo (no corta en el primer byte distinto). */
function sameBytes(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= (a[i] ?? 0) ^ (b[i] ?? 0);
  return diff === 0;
}

async function hmacSha256(key: Uint8Array, message: string): Promise<Uint8Array> {
  const cryptoKey = await crypto.subtle.importKey("raw", new Uint8Array(key), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return new Uint8Array(await crypto.subtle.sign("HMAC", cryptoKey, new TextEncoder().encode(message)));
}

/** La firma Standard Webhooks de `body` con alguna de `keys`, dentro de la tolerancia de tiempo. */
export async function verifyWebhook(keys: readonly Uint8Array[], headers: WebhookHeaders, body: string, now: Date): Promise<WebhookCheck> {
  if (keys.length === 0) return { ok: false, reason: "no_secret" };
  const { id, timestamp, signature } = headers;
  if (!id || !timestamp || !signature || !/^\d{1,12}$/.test(timestamp)) return { ok: false, reason: "missing_headers" };
  if (Math.abs(now.getTime() / 1000 - Number(timestamp)) > WEBHOOK_TOLERANCE_SECONDS) return { ok: false, reason: "stale" };

  const signed = `${id}.${timestamp}.${body}`;
  const given = signature
    .split(" ")
    .map((entry) => /^v1,([A-Za-z0-9+/=]+)$/.exec(entry)?.[1])
    .map((value) => (value ? base64ToBytes(value) : null))
    .filter((value): value is Uint8Array => value !== null);
  for (const key of keys) {
    const expected = await hmacSha256(key, signed);
    if (given.some((candidate) => sameBytes(candidate, expected))) return { ok: true };
  }
  return { ok: false, reason: "bad_signature" };
}

/** Lo que firma `body` (para los tests y para comprobar una implementación contra otra). */
export async function signWebhook(key: Uint8Array, id: string, timestamp: string, body: string): Promise<string> {
  return `v1,${bytesToBase64(await hmacSha256(key, `${id}.${timestamp}.${body}`))}`;
}

/** Lo que el hook usa del pedido de GoTrue. */
export interface HookEmail {
  userId: string;
  /** El destinatario (el email de la cuenta). Nunca a un log. */
  email: string;
  locale: Locale;
  /** El tipo de GoTrue tal como vino (para el log; ya validado como palabra). */
  action: string;
  /** La plantilla, o null si el tipo es desconocido (se rechaza). */
  kind: AuthEmailKind | null;
  token: string;
  tokenHash: string;
}

const isRecord = (value: unknown): value is Record<string, unknown> => typeof value === "object" && value !== null && !Array.isArray(value);
const stringField = (record: Record<string, unknown>, key: string): string => {
  const value = record[key];
  return typeof value === "string" ? value : "";
};

/** El pedido de GoTrue, o null si no tiene la forma esperada. */
export function parseHookPayload(text: string): HookEmail | null {
  let json: unknown;
  try {
    json = JSON.parse(text);
  } catch {
    return null;
  }
  if (!isRecord(json) || !isRecord(json["user"]) || !isRecord(json["email_data"])) return null;
  const user = json["user"];
  const data = json["email_data"];
  const userId = stringField(user, "id").toLowerCase();
  const email = stringField(user, "email").trim();
  const action = stringField(data, "email_action_type");
  if (!isUuid(userId) || email === "" || email.length > 254 || !email.includes("@") || !/^[a-z_]{1,32}$/.test(action)) return null;
  const metadata = isRecord(user["user_metadata"]) ? user["user_metadata"] : {};
  const locale = stringField(metadata, "locale");
  const token = stringField(data, "token");
  const tokenHash = stringField(data, "token_hash");
  // El código son dígitos y el token_hash, hexadecimal (con «pkce_» delante si el alta fue con PKCE): nada más entra
  // al email.
  if (token !== "" && !/^\d{6,10}$/.test(token)) return null;
  if (tokenHash !== "" && !/^(pkce_)?[0-9a-f]{20,128}$/.test(tokenHash)) return null;
  return {
    userId,
    email,
    locale: (LOCALES as readonly string[]).includes(locale) ? (locale as Locale) : DEFAULT_AUTH_LOCALE,
    action,
    kind: Object.hasOwn(ACTION_KINDS, action) ? (ACTION_KINDS[action] ?? null) : null,
    token,
    tokenHash,
  };
}

/** El hash del destinatario que se guarda en la base: HMAC-SHA256 del email en minúsculas con IP_HASH_SALT. */
export async function recipientHash(email: string, salt: string): Promise<string> {
  const mac = await hmacSha256(new TextEncoder().encode(`auth-email:${salt}`), email.trim().toLowerCase());
  return [...mac].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

/** Lo que falta para armar el email de [kind]: el código o el token_hash. */
export function missingValue(kind: AuthEmailKind, email: Pick<HookEmail, "token" | "tokenHash">): boolean {
  if (kind === "magic_link") return email.token === "";
  if (kind === "confirmation" || kind === "recovery") return email.tokenHash === "";
  return false;
}

/** El email (asunto, HTML y texto) de una plantilla que sale: magic_link, confirmation o recovery. */
export function renderHookEmail(kind: AuthEmailKind, email: Pick<HookEmail, "locale" | "token" | "tokenHash">): {
  subject: string;
  html: string;
  text: string;
} {
  const { subject, html } = renderAuthEmail(kind, email.locale, { token: email.token, tokenHash: email.tokenHash });
  const texts = authEmailTexts(kind, email.locale);
  const middle =
    kind === "magic_link"
      ? email.token
      : accessLink(email.locale, encodeURIComponent(email.tokenHash), kind === "confirmation" ? "email" : "recovery");
  return { subject, html, text: `${texts.lead}\n\n${middle}\n\n${texts.note}\n` };
}

/** El cuerpo de error que GoTrue entiende: lo devuelve tal cual a quien pidió el email. */
export function hookError(httpCode: number, message: string): { error: { http_code: number; message: string } } {
  return { error: { http_code: httpCode, message } };
}
