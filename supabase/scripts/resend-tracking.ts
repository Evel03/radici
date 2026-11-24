// Comprueba que Resend NO tiene prendido el seguimiento de aperturas ni de clics (open_tracking y
// click_tracking de GET /domains/{id}). Con el seguimiento prendido, Resend reescribe los links de los
// emails y los manda por su propio dominio: vería los links de acceso. Quien lo apaga es la dueña de la
// cuenta de Resend (panel → Domains → cada dominio); el despliegue solo lo comprueba y corta (docs/
// contracts/auth.md §5). Solo lee: nunca cambia nada en Resend, y nunca imprime la clave.
//
// Con una clave "solo de envío" Resend responde 401 restricted_api_key a GET /domains: no se puede leer.
// Por defecto eso corta (no se da por bueno lo que no se pudo comprobar); con la variable
// RESEND_TRACKING_RESTRICTED_OK=true (que alguien puso a propósito, después de mirar el panel) solo avisa.
//
// Uso (CI): RESEND_API_KEY=… node supabase/scripts/resend-tracking.ts
// Solo sintaxis borrable: corre con node, sin compilar.
import { pathToFileURL } from "node:url";

export interface TrackingDomain {
  name: string;
  /** Qué seguimiento tiene prendido: open_tracking, click_tracking o los dos. */
  tracking: string[];
}

export type TrackingResult =
  | { kind: "ok"; domains: number }
  | { kind: "tracking_on"; domains: TrackingDomain[] }
  | { kind: "restricted" }
  | { kind: "error"; message: string };

const MAX_DOMAINS = 25;

/** Lee los dominios de Resend y dice si alguno tiene seguimiento. [fetchFn] y [baseUrl] solo cambian en los tests. */
export async function checkResendTracking(key: string, fetchFn: typeof fetch = fetch, baseUrl = "https://api.resend.com"): Promise<TrackingResult> {
  const get = async (path: string): Promise<{ status: number; body: Record<string, unknown> }> => {
    const response = await fetchFn(`${baseUrl}${path}`, { method: "GET", headers: { Authorization: `Bearer ${key}` } });
    const body = (await response.json().catch(() => ({}))) as Record<string, unknown>;
    return { status: response.status, body };
  };
  try {
    const list = await get("/domains");
    if (list.status === 401 && list.body.name === "restricted_api_key") return { kind: "restricted" };
    if (list.status !== 200 || !Array.isArray(list.body.data)) return { kind: "error", message: `Resend respondió ${list.status} a GET /domains` };
    const items = list.body.data as Array<{ id?: unknown; name?: unknown }>;
    if (items.length === 0) return { kind: "error", message: "Resend no devolvió ningún dominio: no hay nada que comprobar" };
    if (items.length > MAX_DOMAINS) return { kind: "error", message: `Resend devolvió más de ${MAX_DOMAINS} dominios` };
    const on: TrackingDomain[] = [];
    for (const item of items) {
      const id = typeof item.id === "string" ? item.id : "";
      if (!/^[A-Za-z0-9_-]{1,64}$/.test(id)) return { kind: "error", message: "Resend devolvió un dominio sin id" };
      const detail = await get(`/domains/${id}`);
      const name = typeof detail.body.name === "string" ? detail.body.name : typeof item.name === "string" ? item.name : id;
      if (detail.status !== 200) return { kind: "error", message: `Resend respondió ${detail.status} a GET /domains/{id} (${name})` };
      // Sin estos dos campos no se sabe: no pasa en silencio.
      if (typeof detail.body.open_tracking !== "boolean" || typeof detail.body.click_tracking !== "boolean") {
        return { kind: "error", message: `Resend no informó open_tracking y click_tracking del dominio ${name}` };
      }
      const tracking = [detail.body.open_tracking ? "open_tracking" : "", detail.body.click_tracking ? "click_tracking" : ""].filter(Boolean);
      if (tracking.length > 0) on.push({ name, tracking });
    }
    return on.length > 0 ? { kind: "tracking_on", domains: on } : { kind: "ok", domains: items.length };
  } catch {
    // Nunca el mensaje crudo: podría traer la URL o la cabecera.
    return { kind: "error", message: "no se pudo hablar con Resend" };
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const key = process.env.RESEND_API_KEY ?? "";
  const override = process.env.RESEND_API_URL ?? "";
  const fail = (message: string): never => {
    process.stderr.write(`::error::${message}\n`);
    process.exit(2);
  };
  // La clave nunca va a otro host: solo un servidor local (los tests) puede reemplazar la URL.
  if (override && !/^http:\/\/127\.0\.0\.1:\d+$/.test(override)) fail("RESEND_API_URL solo puede apuntar a 127.0.0.1 (tests)");
  if (!key) fail("Falta RESEND_API_KEY: no se puede comprobar el seguimiento de Resend");
  const result = await checkResendTracking(key, fetch, override || undefined);
  if (result.kind === "ok") {
    process.stdout.write(`Resend: ${result.domains} dominio(s) sin seguimiento de aperturas ni de clics.\n`);
  } else if (result.kind === "tracking_on") {
    const list = result.domains.map((d) => `${d.name} (${d.tracking.join(", ")})`).join("; ");
    fail(`Resend tiene prendido el seguimiento (se revisan todos los dominios de la cuenta): ${list}. Apagarlo en resend.com → Domains → cada dominio → Open Tracking y Click Tracking, y volver a desplegar.`);
  } else if (result.kind === "restricted") {
    if (process.env.RESEND_TRACKING_RESTRICTED_OK === "true") {
      process.stderr.write("::warning::Con una clave solo de envío no se pudo comprobar el seguimiento de Resend (RESEND_TRACKING_RESTRICTED_OK=true): mirar en el panel que Open Tracking y Click Tracking estén apagados.\n");
    } else {
      fail("RESEND_API_KEY es una clave solo de envío: Resend no deja leer el seguimiento de los dominios con ella. Crear una clave con acceso completo, solo para leer, y cargarla como el secreto RESEND_READ_KEY (RESEND_API_KEY la usa la función y sigue siendo solo de envío), o (después de mirar el panel) poner la variable RESEND_TRACKING_RESTRICTED_OK=true.");
    }
  } else {
    fail(`No se pudo comprobar el seguimiento de Resend: ${result.message}.`);
  }
}
