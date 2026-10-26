// Verificación de Cloudflare Turnstile en el servidor (siteverify).
// Docs: https://developers.cloudflare.com/turnstile/get-started/server-side-validation/ (revisado el 19/10/2026).
// En local: secreto 1x0000000000000000000000000000000AA (siempre aprueba) o 2x…AA (siempre rechaza);
// los secretos de prueba solo aceptan el token XXXX.DUMMY.TOKEN.XXXX.
// Solo sintaxis borrable: corre en Node (tests) y Deno (Edge Functions).

export const TURNSTILE_VERIFY_URL = "https://challenges.cloudflare.com/turnstile/v0/siteverify";

/**
 * rejected: el token no vale (vencido, repetido, inválido) → 403.
 * misconfigured: el secreto o el pedido están mal (problema nuestro) → 500.
 * unavailable: Cloudflare no respondió bien → 500.
 */
export type TurnstileOutcome =
  | { ok: true }
  | { ok: false; reason: "rejected" | "misconfigured" | "unavailable"; errorCodes: string[] };

const OUR_FAULT = new Set(["missing-input-secret", "invalid-input-secret", "bad-request"]);

export interface VerifyTurnstileOptions {
  secret: string;
  token: string;
  /** IP del visitante (opcional para Cloudflare, mejora la detección). */
  remoteIp: string | null;
  /** UUID para poder reintentar sin que el token cuente como repetido. */
  idempotencyKey?: string;
  fetch?: typeof fetch;
  timeoutMs?: number;
}

export async function verifyTurnstile(options: VerifyTurnstileOptions): Promise<TurnstileOutcome> {
  const body: Record<string, string> = { secret: options.secret, response: options.token };
  if (options.remoteIp) body["remoteip"] = options.remoteIp;
  if (options.idempotencyKey) body["idempotency_key"] = options.idempotencyKey;

  const doFetch = options.fetch ?? fetch;
  let data: unknown;
  try {
    const response = await doFetch(TURNSTILE_VERIFY_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(options.timeoutMs ?? 8000),
    });
    if (!response.ok) return { ok: false, reason: "unavailable", errorCodes: [`http-${response.status}`] };
    data = await response.json();
  } catch (error) {
    const timedOut = error instanceof Error && (error.name === "TimeoutError" || error.name === "AbortError");
    return { ok: false, reason: "unavailable", errorCodes: [timedOut ? "timeout" : "network"] };
  }

  const record = typeof data === "object" && data !== null ? (data as Record<string, unknown>) : {};
  if (record["success"] === true) return { ok: true };

  const rawCodes = record["error-codes"];
  const errorCodes = Array.isArray(rawCodes) ? rawCodes.filter((code): code is string => typeof code === "string") : [];
  if (errorCodes.includes("internal-error") || typeof record["success"] !== "boolean") {
    return { ok: false, reason: "unavailable", errorCodes };
  }
  if (errorCodes.some((code) => OUR_FAULT.has(code))) return { ok: false, reason: "misconfigured", errorCodes };
  return { ok: false, reason: "rejected", errorCodes };
}
