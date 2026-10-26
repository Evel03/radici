// Envío de emails con la API REST de Resend (POST /emails).
// Docs: https://resend.com/docs/api-reference/emails/send-email y .../idempotency-keys (revisado el 19/10/2026).
// Idempotency-Key: hasta 256 caracteres, se guarda 24 h; el mismo pedido con la misma clave no se
// reenvía. Un solo reintento ante 429, 5xx, 409 "en curso" o error de red, con la misma clave.
// Solo sintaxis borrable: corre en Node (tests) y Deno (Edge Functions).

export const RESEND_API_URL = "https://api.resend.com/emails";

export interface EmailMessage {
  from: string;
  to: string;
  /** A quién van las respuestas (null: al remitente). */
  replyTo: string | null;
  subject: string;
  html: string;
  text: string;
  idempotencyKey: string;
}

/** errorName es el `name` de Resend (ej. validation_error) o "network"; nunca el mensaje, que puede traer la dirección. */
export type SendOutcome = { ok: true; id: string | null } | { ok: false; status: number | null; errorName: string | null };

export interface SendOptions {
  apiKey: string;
  fetch?: typeof fetch;
  sleep?: (ms: number) => Promise<void>;
  timeoutMs?: number;
}

const MAX_RETRY_WAIT_MS = 5000;
const DEFAULT_RETRY_WAIT_MS = 1000;

function retryWait(response: Response | null): number {
  const header = response?.headers.get("retry-after");
  const seconds = header ? Number(header) : Number.NaN;
  if (!Number.isFinite(seconds) || seconds < 0) return DEFAULT_RETRY_WAIT_MS;
  return Math.min(seconds * 1000, MAX_RETRY_WAIT_MS);
}

async function errorName(response: Response): Promise<string | null> {
  try {
    const body: unknown = await response.json();
    const name = typeof body === "object" && body !== null ? (body as Record<string, unknown>)["name"] : null;
    return typeof name === "string" ? name : null;
  } catch {
    return null;
  }
}

export async function sendWithResend(message: EmailMessage, options: SendOptions): Promise<SendOutcome> {
  const doFetch = options.fetch ?? fetch;
  const sleep = options.sleep ?? ((ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms)));
  const payload: Record<string, unknown> = {
    from: message.from,
    to: [message.to],
    subject: message.subject,
    html: message.html,
    text: message.text,
  };
  if (message.replyTo) payload["reply_to"] = message.replyTo;
  const body = JSON.stringify(payload);

  let last: SendOutcome = { ok: false, status: null, errorName: "network" };
  for (let attempt = 1; attempt <= 2; attempt++) {
    let response: Response;
    try {
      response = await doFetch(RESEND_API_URL, {
        method: "POST",
        headers: {
          Authorization: `Bearer ${options.apiKey}`,
          "Content-Type": "application/json",
          "Idempotency-Key": message.idempotencyKey,
        },
        body,
        signal: AbortSignal.timeout(options.timeoutMs ?? 10000),
      });
    } catch {
      last = { ok: false, status: null, errorName: "network" };
      if (attempt === 1) await sleep(DEFAULT_RETRY_WAIT_MS);
      continue;
    }

    if (response.ok) {
      let id: string | null = null;
      try {
        const data: unknown = await response.json();
        const value = typeof data === "object" && data !== null ? (data as Record<string, unknown>)["id"] : null;
        id = typeof value === "string" ? value : null;
      } catch {
        id = null;
      }
      return { ok: true, id };
    }

    const name = await errorName(response);
    last = { ok: false, status: response.status, errorName: name };
    const retryable =
      response.status === 429 || response.status >= 500 || (response.status === 409 && name === "concurrent_idempotent_requests");
    if (!retryable || attempt === 2) return last;
    await sleep(retryWait(response));
  }
  return last;
}
