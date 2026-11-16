// Piezas comunes de las Edge Functions (public-request y chef): logs sin datos personales, errores
// de la base sin datos, la clave de servicio y la lectura del cuerpo con límite de tamaño.
// No dependen de Deno ni de supabase-js: los tests corren en Node.
// Solo sintaxis borrable: corre en Node (tests) y Deno (Edge Functions).

// ---------------------------------------------------------------------------
// Logs: solo valores simples, nunca objetos con datos del pedido
// ---------------------------------------------------------------------------

export type LogLevel = "info" | "warn" | "error";
export type LogValue = string | number | boolean | null | readonly string[];
export type LogFields = Readonly<Record<string, LogValue>>;
export type Logger = (level: LogLevel, event: string, fields?: LogFields) => void;

export const consoleLogger: Logger = (level, event, fields = {}) => {
  const line = JSON.stringify({ level, event, ...fields });
  if (level === "error") console.error(line);
  else if (level === "warn") console.warn(line);
  else console.info(line);
};

// ---------------------------------------------------------------------------
// Errores de la base
// ---------------------------------------------------------------------------

/**
 * Error de la base sin datos: operación, SQLSTATE y, como mucho, un código propio en snake_case y un
 * detalle ya filtrado por quien lo crea (una fecha, un estado o un id; nunca la fila).
 */
export class StoreError extends Error {
  readonly op: string;
  readonly code: string | null;
  readonly safeMessage: string | null;
  readonly safeDetail: string | null;

  constructor(op: string, code: string | null, safeMessage: string | null, safeDetail: string | null = null) {
    super(`db_error:${op}`);
    this.name = "StoreError";
    this.op = op;
    this.code = code;
    this.safeMessage = safeMessage;
    this.safeDetail = safeDetail;
  }
}

/**
 * Los mensajes de Postgres pueden traer la fila (con datos personales). Solo pasan los códigos
 * propios de las funciones SQL, que son identificadores (ej. health_consent_required).
 */
export function safeDbMessage(message: string | null | undefined): string | null {
  return message && /^[a-z][a-z0-9_]{2,63}$/.test(message) ? message : null;
}

/** Deja en el log la operación y el código (y el código propio, si lo hay); nunca el mensaje de Postgres. */
export function logStoreError(log: Logger, error: unknown, op: string): void {
  if (error instanceof StoreError) {
    log("error", "db_error", error.safeMessage ? { op: error.op, code: error.code, message: error.safeMessage } : { op: error.op, code: error.code });
  } else {
    log("error", "db_error", { op, code: null });
  }
}

/**
 * Clave con permisos de servicio para el cliente de Supabase. Primero la clave secreta nueva
 * (SUPABASE_SECRET_KEYS, JSON con nombre → clave; se usa "default"), después las variables de
 * compatibilidad. Las claves service_role (JWT) dejan de existir a fines de 2026.
 */
export function resolveServiceKey(get: (name: string) => string | undefined): string | null {
  const keys = get("SUPABASE_SECRET_KEYS");
  if (keys) {
    try {
      const parsed: unknown = JSON.parse(keys);
      const key = typeof parsed === "object" && parsed !== null ? (parsed as Record<string, unknown>)["default"] : null;
      if (typeof key === "string" && key) return key;
    } catch {
      // JSON roto: se prueba con las otras variables.
    }
  }
  return get("SUPABASE_SECRET_KEY") || get("SUPABASE_SERVICE_ROLE_KEY") || null;
}

// ---------------------------------------------------------------------------
// Cuerpo de la petición
// ---------------------------------------------------------------------------

export function isJsonContentType(value: string | null): boolean {
  return (value ?? "").split(";")[0]?.trim().toLowerCase() === "application/json";
}

export type BodyResult = { ok: true; text: string } | { ok: false; reason: "tooLarge" | "invalid" };

/** Lee el cuerpo sin pasar de `max` bytes (también si no viene Content-Length). UTF-8 inválido: invalid. */
export async function readBodyLimited(request: Request, max: number): Promise<BodyResult> {
  const declared = request.headers.get("content-length");
  if (declared !== null && Number(declared) > max) return { ok: false, reason: "tooLarge" };
  if (!request.body) return { ok: true, text: "" };

  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > max) {
      await reader.cancel().catch(() => {});
      return { ok: false, reason: "tooLarge" };
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  try {
    return { ok: true, text: new TextDecoder("utf-8", { fatal: true }).decode(bytes) };
  } catch {
    return { ok: false, reason: "invalid" };
  }
}
