// El captcha de Auth (Turnstile, docs/contracts/auth.md §10) en el despliegue, en dos momentos, para que un error de
// configuración nunca deje a nadie sin poder pedir el código:
//
// - `secret`, ANTES del PATCH de Auth: la secreta TURNSTILE_AUTH_SECRET_KEY tiene la forma de una secreta real (no una
//   de prueba de Cloudflare) y Cloudflare la reconoce. Se le pregunta a siteverify con un token inventado: con una
//   secreta válida responde «invalid-input-response» (el token no sirve); con una que no existe, «invalid-input-secret».
//   Si algo no da, corta antes de tocar Auth.
// - `auth`, DESPUÉS del PATCH: Auth exige el captcha y tiene la secreta buena. Se le pide un código a una dirección que
//   no existe (sin crear la cuenta): sin token tiene que responder captcha_failed («no captcha_token found»), y con un
//   token inventado, captcha_failed por «invalid-input-response» (Supabase le preguntó a Cloudflare con su secreta y
//   Cloudflare la reconoció). En los dos casos Auth corta antes de hacer nada: no se manda ningún email. Si no da, el
//   script APAGA el captcha (PATCH security_captcha_enabled = false: el login vuelve a andar como antes) y el
//   despliegue falla.
//
// Nunca imprime la secreta, el token de la Management API ni la clave publicable.
// Uso (CI): node supabase/scripts/auth-captcha-check.ts secret|auth
//   secret: TURNSTILE_AUTH_SECRET_KEY
//   auth:   SUPABASE_PROJECT_REF, SUPABASE_PUBLISHABLE_KEY, SUPABASE_ACCESS_TOKEN
// Solo sintaxis borrable: corre con node, sin compilar.
import { pathToFileURL } from "node:url";

export const SITEVERIFY_URL = "https://challenges.cloudflare.com/turnstile/v0/siteverify";
/** Un token que no es de nadie: ni Cloudflare ni Supabase lo pueden aceptar. */
export const DUMMY_TOKEN = "radici-deploy-check.not-a-real-token";
/** Una dirección que no es de nadie (dominio reservado); create_user false: Auth nunca crea la cuenta. */
export const CHECK_EMAIL = "captcha-check@example.com";

export type CheckResult = { kind: "ok" } | { kind: "bad"; message: string };

/** Las secretas de prueba de Cloudflare (1x…: siempre pasa; 2x…: siempre falla; 3x…: token gastado). */
export function isTestSecret(secret: string): boolean {
  return /^[123]x0+[A-Z]{2}$/.test(secret);
}

/** La forma de una secreta real de Turnstile: 0x seguido de letras, dígitos, «_» y «-». */
export function isSecretShape(secret: string): boolean {
  return /^0x[A-Za-z0-9_-]{20,100}$/.test(secret);
}

/** Antes del PATCH: la secreta existe, es real y Cloudflare la reconoce. */
export async function checkSecret(secret: string, fetchFn: typeof fetch = fetch, url = SITEVERIFY_URL): Promise<CheckResult> {
  const value = secret.trim();
  if (!value) return { kind: "bad", message: "falta el secreto TURNSTILE_AUTH_SECRET_KEY (la Secret Key del widget «Radici login» de Turnstile)" };
  if (isTestSecret(value)) return { kind: "bad", message: "TURNSTILE_AUTH_SECRET_KEY es una secreta de prueba de Cloudflare: en producción tiene que ir la del widget real" };
  if (!isSecretShape(value)) return { kind: "bad", message: "TURNSTILE_AUTH_SECRET_KEY no tiene la forma de una secreta de Turnstile (0x…): ¿espacios, comillas o la sitekey en su lugar?" };
  let codes: string[];
  try {
    const response = await fetchFn(url, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ secret: value, response: DUMMY_TOKEN }).toString(),
    });
    const json: unknown = await response.json().catch(() => null);
    if (typeof json !== "object" || json === null) return { kind: "bad", message: `Cloudflare respondió ${response.status} sin un JSON legible` };
    const body = json as Record<string, unknown>;
    if (body["success"] === true) return { kind: "bad", message: "Cloudflare aceptó un token inventado: la secreta no es la de un widget real" };
    const raw = body["error-codes"];
    codes = Array.isArray(raw) ? raw.filter((c): c is string => typeof c === "string") : [];
  } catch {
    return { kind: "bad", message: "no se pudo consultar a Cloudflare (siteverify): sin comprobar la secreta no se prende el captcha" };
  }
  if (codes.includes("invalid-input-secret")) return { kind: "bad", message: "Cloudflare no reconoce TURNSTILE_AUTH_SECRET_KEY (invalid-input-secret): copiar de nuevo la Secret Key del widget" };
  if (codes.includes("invalid-input-response")) return { kind: "ok" };
  return { kind: "bad", message: `respuesta inesperada de Cloudflare (${codes.join(", ") || "sin códigos"})` };
}

export interface AuthCheckOptions {
  projectRef: string;
  publishableKey: string;
  accessToken: string;
  fetchFn?: typeof fetch;
  /** Solo los tests la cambian. */
  authBase?: string;
  managementBase?: string;
}

interface AuthReply {
  status: number;
  code: string | null;
  message: string;
}

/** Un pedido de código, sin crear la cuenta, con o sin token. Null si no hubo respuesta. */
async function requestCode(options: AuthCheckOptions, token: string | null): Promise<AuthReply | null> {
  const fetchFn = options.fetchFn ?? fetch;
  const base = options.authBase ?? `https://${options.projectRef}.supabase.co`;
  const body: Record<string, unknown> = { email: CHECK_EMAIL, create_user: false };
  if (token) body["gotrue_meta_security"] = { captcha_token: token };
  try {
    const response = await fetchFn(`${base}/auth/v1/otp`, {
      method: "POST",
      headers: { apikey: options.publishableKey, "Content-Type": "application/json", "X-Supabase-Api-Version": "2024-01-01" },
      body: JSON.stringify(body),
    });
    const json = (await response.json().catch(() => ({}))) as Record<string, unknown>;
    const code = typeof json["code"] === "string" ? json["code"] : typeof json["error_code"] === "string" ? json["error_code"] : null;
    const message = String(json["message"] ?? json["msg"] ?? "");
    return { status: response.status, code, message };
  } catch {
    return null;
  }
}

/** Después del PATCH: Auth exige el captcha y Cloudflare reconoce la secreta que tiene Supabase. */
export async function checkAuthRequiresCaptcha(options: AuthCheckOptions): Promise<CheckResult> {
  const without = await requestCode(options, null);
  if (!without) return { kind: "bad", message: "Auth no respondió al pedido de código de prueba" };
  if (without.status !== 400 || without.code !== "captcha_failed") {
    return { kind: "bad", message: `sin token, Auth respondió ${without.status} ${without.code ?? ""} en lugar de captcha_failed: no está exigiendo el captcha` };
  }
  const dummy = await requestCode(options, DUMMY_TOKEN);
  if (!dummy) return { kind: "bad", message: "Auth no respondió al pedido con el token inventado" };
  if (dummy.code === "captcha_failed" && dummy.message.includes("invalid-input-response")) return { kind: "ok" };
  if (dummy.message.includes("invalid-input-secret")) {
    return { kind: "bad", message: "Supabase tiene una secreta que Cloudflare no reconoce (invalid-input-secret)" };
  }
  return { kind: "bad", message: `con un token inventado, Auth respondió ${dummy.status} ${dummy.code ?? ""}: el captcha no quedó bien` };
}

/** Vuelta atrás automática: apaga el captcha de Auth (el login sigue como antes de prenderlo). */
export async function disableCaptcha(options: AuthCheckOptions): Promise<boolean> {
  const fetchFn = options.fetchFn ?? fetch;
  const base = options.managementBase ?? "https://api.supabase.com";
  try {
    const response = await fetchFn(`${base}/v1/projects/${options.projectRef}/config/auth`, {
      method: "PATCH",
      headers: { Authorization: `Bearer ${options.accessToken}`, "Content-Type": "application/json" },
      body: JSON.stringify({ security_captcha_enabled: false }),
    });
    return response.status === 200;
  } catch {
    return false;
  }
}

/** `auth`: comprueba y, si no da, apaga el captcha. Devuelve el mensaje de error, o null si quedó bien. */
export async function verifyOrRollback(options: AuthCheckOptions): Promise<string | null> {
  const result = await checkAuthRequiresCaptcha(options);
  if (result.kind === "ok") return null;
  const off = await disableCaptcha(options);
  return off
    ? `${result.message}. Se apagó el captcha de Auth (el login sigue como antes); revisar la secreta y el widget, y volver a desplegar`
    : `${result.message}. Y NO se pudo apagar el captcha: apagarlo a mano ya (auth.md §10, «Vuelta atrás»)`;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const fail = (message: string): never => {
    process.stderr.write(`::error::Captcha de Auth: ${message}\n`);
    process.exit(1);
  };
  const part = process.argv[2];
  if (part === "secret") {
    const result = await checkSecret(process.env["TURNSTILE_AUTH_SECRET_KEY"] ?? "");
    if (result.kind === "bad") fail(result.message);
    process.stdout.write("La secreta de Turnstile de Auth es la de un widget real.\n");
  } else if (part === "auth") {
    const options = {
      projectRef: process.env["SUPABASE_PROJECT_REF"] ?? "",
      publishableKey: process.env["SUPABASE_PUBLISHABLE_KEY"] ?? "",
      accessToken: process.env["SUPABASE_ACCESS_TOKEN"] ?? "",
    };
    if (!options.projectRef || !options.publishableKey || !options.accessToken) {
      fail("faltan SUPABASE_PROJECT_REF, SUPABASE_PUBLISHABLE_KEY o SUPABASE_ACCESS_TOKEN para comprobar el captcha");
    }
    const error = await verifyOrRollback(options);
    if (error) fail(error);
    process.stdout.write("Auth exige el captcha y Cloudflare reconoce su secreta.\n");
  } else {
    fail("uso: node supabase/scripts/auth-captcha-check.ts secret|auth");
  }
}
