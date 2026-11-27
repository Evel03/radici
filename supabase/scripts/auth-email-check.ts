// Comprueba, ANTES de prender el hook de envío (PR20, docs/contracts/auth.md §16), que la función auth-email de
// producción contesta y tiene el mismo secreto que se le va a dar a Auth. Si no, el despliegue deja las altas cerradas
// y el hook apagado: un hook prendido que no contesta deja a todos sin emails de Auth (el código de Evelyn incluido).
//
// Dos pedidos, ninguno manda un email:
//   1. sin firma: tiene que contestar 401 invalid_signature (la función tiene un secreto y lo exige). 503 = la función
//      no tiene SEND_EMAIL_HOOK_SECRETS;
//   2. firmado con SEND_EMAIL_HOOK_SECRET, como «invite» de una cuenta que no existe: tiene que contestar 200 con
//      {"error": {"http_code": 403, "message": "email_not_allowed"}} (la firma coincide y la función rechaza lo que
//      Radici no usa, sin preguntarle a la base). 401 = el secreto de la función es otro.
// Nunca imprime el secreto ni el cuerpo de una respuesta.
//
// Uso (CI): SUPABASE_PROJECT_REF=… SEND_EMAIL_HOOK_SECRET=… node supabase/scripts/auth-email-check.ts
// Solo sintaxis borrable: corre con node, sin compilar.
import { pathToFileURL } from "node:url";
import { parseHookSecrets, signWebhook } from "../functions/_shared/auth_email_hook.ts";

export type AuthEmailCheck = { kind: "ok" } | { kind: "bad"; problem: string };

/** El secreto del hook tiene la forma de Standard Webhooks: un solo "v1,whsec_<base64>" de 32 bytes o más. */
export function validHookSecret(secret: string): boolean {
  return /^v1,whsec_[A-Za-z0-9+/]+={0,2}$/.test(secret) && (parseHookSecrets(secret)[0]?.length ?? 0) >= 32;
}

export function authEmailUrl(projectRef: string): string {
  return `https://${projectRef}.supabase.co/functions/v1/auth-email`;
}

/** El error del cuerpo ({"error": {"http_code", "message"}}), o null. */
async function hookErrorOf(response: Response): Promise<{ code: unknown; message: unknown } | null> {
  try {
    const body: unknown = await response.json();
    const error = typeof body === "object" && body !== null ? (body as Record<string, unknown>)["error"] : null;
    if (typeof error !== "object" || error === null) return null;
    const record = error as Record<string, unknown>;
    return { code: record["http_code"], message: record["message"] };
  } catch {
    return null;
  }
}

export async function checkAuthEmail(options: {
  url: string;
  secret: string;
  fetchFn?: typeof fetch;
  now?: Date;
  /** El id del webhook de prueba (los tests lo fijan). */
  id?: string;
}): Promise<AuthEmailCheck> {
  const fetchFn = options.fetchFn ?? fetch;
  const key = parseHookSecrets(options.secret)[0];
  if (!key || !validHookSecret(options.secret)) return { kind: "bad", problem: "SEND_EMAIL_HOOK_SECRET no tiene la forma v1,whsec_<base64 de 32 bytes>" };
  const body = JSON.stringify({
    user: { id: crypto.randomUUID(), email: "hook-check@radicicucina.app", user_metadata: {}, app_metadata: {} },
    email_data: { token: "", token_hash: "", redirect_to: "", email_action_type: "invite", site_url: "", token_new: "", token_hash_new: "" },
  });
  try {
    const unsigned = await fetchFn(options.url, { method: "POST", headers: { "Content-Type": "application/json" }, body });
    if (unsigned.status === 503) return { kind: "bad", problem: "la función auth-email no tiene SEND_EMAIL_HOOK_SECRETS (503)" };
    if (unsigned.status !== 401 || (await hookErrorOf(unsigned))?.message !== "invalid_signature") {
      return { kind: "bad", problem: `sin firma, la función contestó ${unsigned.status} en lugar de 401` };
    }

    const id = options.id ?? `msg_check_${crypto.randomUUID()}`;
    const timestamp = String(Math.floor((options.now ?? new Date()).getTime() / 1000));
    const signed = await fetchFn(options.url, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "webhook-id": id,
        "webhook-timestamp": timestamp,
        "webhook-signature": await signWebhook(key, id, timestamp, body),
      },
      body,
    });
    if (signed.status === 401) return { kind: "bad", problem: "la función tiene otro secreto (401 con la firma de SEND_EMAIL_HOOK_SECRET)" };
    const refused = signed.status === 200 ? await hookErrorOf(signed) : null;
    if (refused?.code !== 403 || refused.message !== "email_not_allowed") {
      return { kind: "bad", problem: `firmado, la función contestó ${signed.status} en lugar de 200 con el error 403 email_not_allowed` };
    }
    return { kind: "ok" };
  } catch {
    // Nunca el mensaje crudo.
    return { kind: "bad", problem: "no se pudo hablar con la función auth-email" };
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const ref = process.env.SUPABASE_PROJECT_REF ?? "";
  const secret = (process.env.SEND_EMAIL_HOOK_SECRET ?? "").trim();
  const override = process.env.AUTH_EMAIL_URL ?? "";
  const fail = (message: string): never => {
    process.stderr.write(`::error::${message}\n`);
    process.exit(2);
  };
  // El secreto firma pedidos: solo a la función del proyecto o a un servidor local (los tests).
  if (override && !/^http:\/\/127\.0\.0\.1:\d+\/functions\/v1\/auth-email$/.test(override)) fail("AUTH_EMAIL_URL solo puede apuntar a 127.0.0.1 (tests)");
  if (!/^[a-z]{20}$/.test(ref) && !override) fail("SUPABASE_PROJECT_REF no es una referencia de proyecto válida");
  const result = await checkAuthEmail({ url: override || authEmailUrl(ref), secret });
  if (result.kind === "ok") {
    process.stdout.write("Hook de envío: auth-email contesta, exige la firma y tiene el mismo secreto (rechaza una invitación, sin mandar nada).\n");
  } else {
    fail(`El hook de envío no se puede prender: ${result.problem}.`);
  }
}
