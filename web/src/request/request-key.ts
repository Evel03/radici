// Clave de idempotencia del pedido (`requestKey` del contrato, public_request.ts): un UUID por pedido,
// reutilizado en los reintentos. Si llega dos veces la misma clave, el servidor devuelve el pedido ya
// guardado y no repite los avisos: un reintento nunca duplica el pedido.
//
// Cuándo se conserva la clave:
// - Error de red, 5xx o 429: el reintento, con o sin cambios en el formulario, usa la misma. Con red o
//   5xx el servidor pudo haberlo guardado aunque no llegó la respuesta; con 429 no, pero es el mismo
//   pedido esperando turno.
// Cuándo cambia:
// - Después de un pedido guardado (2xx): el próximo envío es otro pedido.
// - Si el servidor lo rechazó con certeza por los datos o la verificación (400, 403, 413) y después el
//   cliente cambia el formulario: los datos nuevos son otro pedido.
//   Excepción: si con esta clave ya hubo un error de red o 5xx, se conserva hasta el 2xx. Ese primer
//   envío pudo haber quedado guardado y una clave nueva lo duplicaría.
//
// Si el reintento recibe `duplicate: true`, lo guardado es lo de un envío anterior (uno que terminó en
// error de red o 5xx), no lo que se acaba de mandar: `replayed` dice cuál, si se puede saber, para que
// la pantalla de gracias no muestre como enviado lo que se cambió después.
import type { RequestData } from "./model.ts";
import type { SubmitOutcome } from "./submit.ts";

/** La parte de `crypto` que se usa (en los tests, una simulada). */
export interface RandomSource {
  randomUUID?(): string;
  getRandomValues?(array: Uint8Array<ArrayBuffer>): Uint8Array<ArrayBuffer>;
}

/**
 * UUID versión 4 en minúsculas. crypto.randomUUID solo existe en contextos seguros (https o localhost)
 * y en navegadores recientes (Safari 15.4+): si falta, se arma con crypto.getRandomValues (Safari 14 y
 * http en la red local), y sin crypto, con Math.random (alcanza: es una clave de idempotencia, no un secreto).
 */
export function newRequestKey(random: RandomSource | null = globalThis.crypto ?? null): string {
  if (typeof random?.randomUUID === "function") return random.randomUUID().toLowerCase();
  const bytes = new Uint8Array(16);
  if (typeof random?.getRandomValues === "function") random.getRandomValues(bytes);
  else for (let i = 0; i < bytes.length; i += 1) bytes[i] = Math.floor(Math.random() * 256);
  // RFC 9562: los 4 bits altos del byte 6 son la versión (4) y los 2 altos del byte 8, la variante (10).
  bytes[6] = ((bytes[6] ?? 0) & 0x0f) | 0x40;
  bytes[8] = ((bytes[8] ?? 0) & 0x3f) | 0x80;
  const hex = Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

/** Resultado de un envío, como lo clasifica submit.ts. */
export type AttemptOutcome = SubmitOutcome["kind"];

/** Sin respuesta clara: el servidor pudo haber guardado el pedido. */
const MAYBE_SAVED: ReadonlySet<AttemptOutcome> = new Set<AttemptOutcome>(["network", "server"]);
/** Rechazo seguro por los datos o la verificación: el servidor no lo guardó. */
const REJECTED: ReadonlySet<AttemptOutcome> = new Set<AttemptOutcome>(["invalid", "turnstile", "tooLarge"]);

/** Qué tiene guardado el servidor cuando contesta un reintento con `duplicate: true`. */
export type SavedData =
  /** Lo mismo que se acaba de mandar: el formulario no cambió desde el envío que quedó guardado. */
  | { kind: "sent" }
  /** Lo de un envío anterior, con otros datos (los cambios de después no se guardaron). */
  | { kind: "earlier"; formSnapshot: string }
  /** Hubo varios envíos sin respuesta con datos distintos: no se sabe cuál llegó. */
  | { kind: "unknown" };

export interface RequestKeys {
  /** Clave para el envío que empieza: la misma mientras no haga falta una nueva. */
  current(): string;
  /**
   * Resultado de un envío.
   * @param formSnapshot los datos del formulario que se mandaron, serializados (JSON).
   */
  settle(outcome: AttemptOutcome, formSnapshot: string): void;
  /**
   * El formulario cambió (o se va a enviar: se llama también antes de cada envío, por si se editó
   * mientras se enviaba el anterior). Después de un rechazo seguro, datos distintos llevan clave nueva.
   */
  edited(formSnapshot: string): void;
  /**
   * El envío de `formSnapshot` recibió un 2xx con `duplicate: true`: qué datos tiene guardados el
   * servidor. Llamarlo antes de settle("created"), que olvida los envíos anteriores.
   */
  replayed(formSnapshot: string): SavedData;
}

export function createRequestKeys(generate: () => string = newRequestKey): RequestKeys {
  let key: string | null = null;
  /** Datos de los envíos con esta clave que terminaron en error de red o 5xx: pueden estar guardados. */
  let maybeSaved: string[] = [];
  /** Datos que el servidor rechazó con certeza con esta clave (null si el último envío no fue un rechazo). */
  let rejected: string | null = null;

  return {
    current() {
      key ??= generate();
      return key;
    },
    settle(outcome, formSnapshot) {
      if (outcome === "created") {
        key = null;
        maybeSaved = [];
        rejected = null;
        return;
      }
      if (MAYBE_SAVED.has(outcome) && !maybeSaved.includes(formSnapshot)) maybeSaved.push(formSnapshot);
      rejected = REJECTED.has(outcome) ? formSnapshot : null;
    },
    edited(formSnapshot) {
      if (rejected === null || formSnapshot === rejected) return;
      rejected = null;
      if (maybeSaved.length === 0) key = null;
    },
    replayed(formSnapshot) {
      // Se guardó uno solo de los envíos sin respuesta (el primero que llegó a la base).
      const [only, ...others] = maybeSaved;
      if (only === undefined || others.length > 0) return { kind: "unknown" };
      return only === formSnapshot ? { kind: "sent" } : { kind: "earlier", formSnapshot: only };
    },
  };
}

/** Pantalla de gracias: con qué datos (null: no se sabe) y qué aviso de reintento mostrar. */
export interface DoneView {
  data: RequestData | null;
  replay: "earlier" | "unknown" | null;
}

/** Qué muestra la pantalla de gracias según lo guardado: nunca como enviado algo que no se guardó. */
export function doneViewFor(saved: SavedData, sent: RequestData): DoneView {
  switch (saved.kind) {
    case "sent":
      return { data: sent, replay: null };
    case "earlier":
      try {
        // Lo serializó la propia página (JSON.stringify de readForm): misma forma que RequestData.
        return { data: JSON.parse(saved.formSnapshot) as RequestData, replay: "earlier" };
      } catch {
        return { data: null, replay: "unknown" };
      }
    case "unknown":
      return { data: null, replay: "unknown" };
  }
}
