// Lógica de la Edge Function auth-email: el Send Email Hook de Supabase Auth (PR19, contrato docs/contracts/auth.md
// §16). Se despliega en PR19 pero GoTrue no la llama hasta que PR20 prenda el hook: mientras tanto los emails de Auth
// salen como siempre, con las plantillas de GoTrue.
// No depende de Deno ni de supabase-js: index.ts arma las dependencias reales y los tests las simulan.
//
// Orden: método (405) → cuerpo (413/400) → firma Standard Webhooks (401; sin secreto, 503) → pedido de GoTrue (400)
// → public.auth_email_gate (500 si falla) → reject (403), skip (200 sin mandar), limited (429) o send → email
// configurado (503) → Resend (502 si no sale) → 200 {}.
// Cada error va en la forma que GoTrue devuelve a quien pidió el email: {"error": {"http_code", "message"}}.
//
// Los logs llevan solo el evento, el tipo de email y la decisión: nunca el destinatario, el código, el token_hash ni
// el id del usuario.
// Solo sintaxis borrable: corre en Node (tests) y Deno (Edge Functions).
import type { AuthEmailKind } from "../_shared/auth_emails.ts";
import {
  HOOK_MAX_BODY_BYTES,
  hookError,
  missingValue,
  parseHookPayload,
  recipientHash,
  renderHookEmail,
  verifyWebhook,
} from "../_shared/auth_email_hook.ts";
import { logStoreError, readBodyLimited, type Logger } from "../_shared/edge.ts";
import type { EmailMessage, SendOutcome } from "../_shared/resend.ts";

export type GateDecision = "send" | "skip" | "reject" | "limited";
export const GATE_DECISIONS: readonly GateDecision[] = ["send", "skip", "reject", "limited"];
/** Las únicas plantillas que pueden salir por el hook (las demás se rechazan sin preguntarle a la base). */
export const SENDABLE_KINDS: readonly AuthEmailKind[] = ["magic_link", "confirmation", "recovery"];

export interface AuthEmailConfig {
  /** SEND_EMAIL_HOOK_SECRETS ya decodificados (parseHookSecrets). Sin ninguno, 503. */
  hookKeys: readonly Uint8Array[];
  /** IP_HASH_SALT: el hash del destinatario. Sin él, 503 (no se guarda nada sin hash). */
  hashSalt: string | null;
  /** RESEND_AUTH_KEY: la clave de Resend de los emails de Auth (aparte de la de los pedidos). */
  resendKey: string | null;
  mailFrom: string | null;
  /** EMAIL_TRANSPORT=log: no manda (como las demás funciones, para desarrollo). */
  emailTransport: "log" | "resend";
}

export interface AuthEmailStore {
  /** public.auth_email_gate: si sale (y lo anota), no sale, se rechaza o pasó un tope. */
  gate(userId: string, kind: AuthEmailKind, recipientHash: string): Promise<GateDecision>;
}

export interface AuthEmailDeps {
  config: AuthEmailConfig;
  store: AuthEmailStore;
  sendEmail: (message: EmailMessage, apiKey: string) => Promise<SendOutcome>;
  log: Logger;
  now: () => Date;
}

const JSON_HEADERS = { "Content-Type": "application/json", "Cache-Control": "no-store" };

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: JSON_HEADERS });
}

function fail(status: number, message: string): Response {
  return json(status, hookError(status, message));
}

/** La clave de idempotencia de Resend: el id del webhook (lo repite GoTrue si reintenta), con prefijo. */
async function idempotencyKey(webhookId: string): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(webhookId)));
  return `auth-email-${[...digest].map((byte) => byte.toString(16).padStart(2, "0")).join("")}`;
}

export function createAuthEmailHandler(deps: AuthEmailDeps): (request: Request) => Promise<Response> {
  const { config, store, log } = deps;
  return async (request) => {
    if (request.method !== "POST") return fail(405, "method_not_allowed");

    const body = await readBodyLimited(request, HOOK_MAX_BODY_BYTES);
    if (!body.ok) return fail(body.reason === "tooLarge" ? 413 : 400, "invalid_body");

    const check = await verifyWebhook(
      config.hookKeys,
      {
        id: request.headers.get("webhook-id"),
        timestamp: request.headers.get("webhook-timestamp"),
        signature: request.headers.get("webhook-signature"),
      },
      body.text,
      deps.now(),
    );
    if (!check.ok) {
      log(check.reason === "no_secret" ? "error" : "warn", "hook_unauthorized", { reason: check.reason });
      return check.reason === "no_secret" ? fail(503, "hook_not_configured") : fail(401, "invalid_signature");
    }

    const email = parseHookPayload(body.text);
    if (!email) {
      log("warn", "hook_invalid_payload");
      return fail(400, "invalid_payload");
    }
    if (email.kind === null) {
      log("warn", "hook_rejected", { action: email.action });
      return fail(403, "email_not_allowed");
    }
    const kind = email.kind;
    // Cambio de email, invitación y reautenticación: se rechazan acá mismo, aunque la base no conteste (la base dice
    // lo mismo: auth_email_gate devuelve reject).
    if (!SENDABLE_KINDS.includes(kind)) {
      log("info", "hook_rejected", { kind });
      return fail(403, "email_not_allowed");
    }
    if (!config.hashSalt) {
      log("error", "hook_not_configured", { missing: ["IP_HASH_SALT"] });
      return fail(503, "hook_not_configured");
    }

    let decision: GateDecision;
    try {
      decision = await store.gate(email.userId, kind, await recipientHash(email.email, config.hashSalt));
    } catch (error) {
      logStoreError(log, error, "auth_email_gate");
      return fail(500, "gate_failed");
    }

    switch (decision) {
      case "reject":
        log("info", "hook_rejected", { kind });
        return fail(403, "email_not_allowed");
      case "skip":
        // 200 sin mandar nada: la respuesta no dice si la cuenta es de la cocina.
        log("info", "hook_skipped", { kind });
        return json(200, {});
      case "limited":
        log("warn", "hook_limited", { kind });
        return fail(429, "too_many_emails");
      case "send":
        break;
    }

    if (missingValue(kind, email)) {
      log("error", "hook_missing_value", { kind });
      return fail(400, "invalid_payload");
    }
    const rendered = renderHookEmail(kind, email);
    if (config.emailTransport === "log") {
      log("info", "hook_email_logged", { kind });
      return json(200, {});
    }
    if (!config.resendKey || !config.mailFrom) {
      log("error", "hook_not_configured", {
        missing: [config.resendKey ? "" : "RESEND_AUTH_KEY", config.mailFrom ? "" : "MAIL_FROM"].filter(Boolean),
      });
      return fail(503, "email_not_configured");
    }
    const outcome = await deps.sendEmail(
      {
        from: config.mailFrom,
        to: email.email,
        replyTo: null,
        subject: rendered.subject,
        html: rendered.html,
        text: rendered.text,
        idempotencyKey: await idempotencyKey(request.headers.get("webhook-id") ?? ""),
      },
      config.resendKey,
    );
    if (!outcome.ok) {
      log("error", "hook_send_failed", { kind, status: outcome.status, error: outcome.errorName });
      return fail(502, "email_not_sent");
    }
    log("info", "hook_sent", { kind });
    return json(200, {});
  };
}
