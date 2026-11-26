// Las llamadas de /accesso/ a Supabase Auth (GoTrue), con fetch y sin supabase-js: supabase-js guardaría la sesión en
// localStorage, y acá la sesión vive solo en memoria y dura lo que tarda en elegirse la contraseña.
// - POST /verify con SOLO type y token_hash (GoTrue rechaza cualquier otro campo junto al token_hash).
// - PUT /user con la contraseña nueva: la sesión de /verify tiene amr otp, que GoTrue cuenta como recuperación
//   (Session.IsRecovery), así que no pide la actual aunque Auth tenga require_current_password.
// - POST /logout?scope=local: cierra solo esta sesión.
// - «Reinvia»: POST /resend (type signup) para el alta, POST /recover para la contraseña, con el token del captcha. Las
//   dos responden igual exista o no la cuenta (200 vacío), y la página muestra el mismo mensaje.
// Cada respuesta se reduce a unos pocos casos que la página sabe mostrar. Nada de esto se registra en la consola.
import type { AccessLink, LinkType } from "./link.ts";

export type VerifyResult =
  | { readonly kind: "ok"; readonly accessToken: string; readonly email: string }
  /** Vencido, ya usado o no válido: GoTrue responde 403 otp_expired (o 400 si el link vino mal). */
  | { readonly kind: "expired" }
  | { readonly kind: "rateLimited" }
  /** Sin conexión, error del servidor o una respuesta que no se entiende. */
  | { readonly kind: "failed" };

export type UpdateResult =
  | { readonly kind: "ok" }
  /** reasons: las de GoTrue (length, characters, pwned); vacío si no las dio. */
  | { readonly kind: "weak"; readonly reasons: readonly string[] }
  | { readonly kind: "same" }
  /** La sesión ya no sirve (venció o se cerró): hace falta otro link. */
  | { readonly kind: "session" }
  | { readonly kind: "rateLimited" }
  | { readonly kind: "failed" };

export type ResendResult =
  | { readonly kind: "ok" }
  | { readonly kind: "captcha" }
  | { readonly kind: "invalidEmail" }
  | { readonly kind: "rateLimited" }
  | { readonly kind: "failed" };

export interface AuthApi {
  /** false si el build no tiene la URL de Supabase o la clave publicable: la página no puede hacer nada. */
  readonly available: boolean;
  verify(link: AccessLink): Promise<VerifyResult>;
  updatePassword(accessToken: string, password: string): Promise<UpdateResult>;
  /** Nunca lanza: si falla, la sesión igual se olvida (vive solo en memoria y vence sola). */
  logout(accessToken: string): Promise<void>;
  resend(type: LinkType, email: string, captchaToken: string): Promise<ResendResult>;
}

export interface AuthApiOptions {
  supabaseUrl: string | null;
  publishableKey: string | null;
  fetch?: typeof fetch;
  /** Tiempo máximo de cada llamada (por defecto 15 s). */
  timeoutMs?: number;
}

/** Con esta versión GoTrue manda el código de error en `code` (sin ella, en `error_code`): se leen los dos. */
const API_VERSION = "2024-01-01";
const DEFAULT_TIMEOUT_MS = 15_000;
const SESSION_CODES = new Set(["session_not_found", "session_expired", "bad_jwt", "reauthentication_needed", "current_password_required"]);

interface Reply {
  readonly status: number;
  readonly code: string | null;
  readonly body: Record<string, unknown> | null;
}

function errorCode(body: Record<string, unknown> | null): string | null {
  if (!body) return null;
  if (typeof body["code"] === "string") return body["code"];
  if (typeof body["error_code"] === "string") return body["error_code"];
  return null;
}

export function createAuthApi(options: AuthApiOptions): AuthApi {
  const doFetch = options.fetch ?? ((input: RequestInfo | URL, init?: RequestInit) => globalThis.fetch(input, init));
  const timeoutMs = options.timeoutMs ?? DEFAULT_TIMEOUT_MS;
  const base = options.supabaseUrl ? `${options.supabaseUrl}/auth/v1` : null;
  const key = options.publishableKey;
  const available = base !== null && key !== null;

  /** Una llamada a Auth. null si no hubo respuesta (sin conexión, tiempo, configuración que falta). */
  const call = async (method: string, path: string, body: unknown, accessToken?: string): Promise<Reply | null> => {
    if (!base || !key) return null;
    const headers: Record<string, string> = { apikey: key, "Content-Type": "application/json", "X-Supabase-Api-Version": API_VERSION };
    if (accessToken) headers["Authorization"] = `Bearer ${accessToken}`;
    const init: RequestInit = {
      method,
      headers,
      credentials: "omit",
      cache: "no-store",
      referrerPolicy: "no-referrer",
      redirect: "error",
    };
    if (body !== undefined) init.body = JSON.stringify(body);
    // AbortSignal.timeout no existe en Safari < 16: ahí la llamada espera lo que espere el navegador.
    if (typeof AbortSignal !== "undefined" && typeof AbortSignal.timeout === "function") init.signal = AbortSignal.timeout(timeoutMs);
    let response: Response;
    try {
      response = await doFetch(`${base}${path}`, init);
    } catch {
      return null;
    }
    let parsed: Record<string, unknown> | null = null;
    try {
      const json: unknown = await response.json();
      if (typeof json === "object" && json !== null && !Array.isArray(json)) parsed = json as Record<string, unknown>;
    } catch {
      // Sin cuerpo (204) o no es JSON.
    }
    return { status: response.status, code: response.ok ? null : errorCode(parsed), body: parsed };
  };

  return {
    available,

    async verify(link) {
      const reply = await call("POST", "/verify", { type: link.type, token_hash: link.tokenHash });
      if (!reply) return { kind: "failed" };
      if (reply.status === 200) {
        const token = reply.body?.["access_token"];
        const user = reply.body?.["user"];
        const email = typeof user === "object" && user !== null ? (user as Record<string, unknown>)["email"] : null;
        if (typeof token !== "string" || token === "") return { kind: "failed" };
        return { kind: "ok", accessToken: token, email: typeof email === "string" ? email : "" };
      }
      if (reply.status === 429) return { kind: "rateLimited" };
      if (reply.status >= 400 && reply.status < 500) return { kind: "expired" };
      return { kind: "failed" };
    },

    async updatePassword(accessToken, password) {
      const reply = await call("PUT", "/user", { password }, accessToken);
      if (!reply) return { kind: "failed" };
      if (reply.status === 200) return { kind: "ok" };
      if (reply.status === 429) return { kind: "rateLimited" };
      if (reply.code === "weak_password") {
        const raw = reply.body?.["weak_password"];
        const reasons = typeof raw === "object" && raw !== null ? (raw as Record<string, unknown>)["reasons"] : null;
        return { kind: "weak", reasons: Array.isArray(reasons) ? reasons.filter((r): r is string => typeof r === "string") : [] };
      }
      if (reply.code === "same_password") return { kind: "same" };
      if (reply.status === 401 || reply.status === 403 || (reply.code !== null && SESSION_CODES.has(reply.code))) return { kind: "session" };
      if (reply.status === 422) return { kind: "weak", reasons: [] };
      return { kind: "failed" };
    },

    async logout(accessToken) {
      try {
        await call("POST", "/logout?scope=local", undefined, accessToken);
      } catch {
        // Nunca lanza.
      }
    },

    async resend(type, email, captchaToken) {
      const security = { captcha_token: captchaToken };
      const reply =
        type === "email"
          ? await call("POST", "/resend", { type: "signup", email, gotrue_meta_security: security })
          : await call("POST", "/recover", { email, gotrue_meta_security: security });
      if (!reply) return { kind: "failed" };
      if (reply.status === 200) return { kind: "ok" };
      if (reply.status === 429) return { kind: "rateLimited" };
      if (reply.code === "captcha_failed") return { kind: "captcha" };
      if (reply.code === "email_address_invalid" || reply.code === "validation_failed") return { kind: "invalidEmail" };
      return { kind: "failed" };
    },
  };
}
