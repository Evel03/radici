// La página /preferenze/ (contrato public-request §13), pura: qué se ve y qué pasa con cada toque. Al abrir, solo
// pregunta el estado (no cambia nada: un escáner de links que abre la página no confirma a nadie); confirmar o darse
// de baja necesitan un toque. Nada se guarda: ni localStorage, ni sessionStorage, ni cookies.
import type { MarketingStatus } from "../../../supabase/functions/_shared/marketing.ts";
import type { MarketingApi, MarketingOutcome } from "./api.ts";

export type PreferencesError = "network" | "rateLimited" | "server";

export type PreferencesState =
  /** El link no trae un token con la forma de uno. */
  | { step: "missing" }
  | { step: "loading" }
  /** El link no es de nadie o venció (los pendientes, a los 7 días). */
  | { step: "notFound" }
  /** No se pudo leer el estado: se reintenta con el mismo botón. */
  | { step: "failed"; error: PreferencesError }
  /** El estado del contacto. `busy` mientras confirma o da de baja; `error`, si eso falló. */
  | { step: MarketingStatus; email: string | null; busy: boolean; error: PreferencesError | null };

export interface Preferences {
  state(): PreferencesState;
  /** Lee el estado (al abrir, o «Riprova» después de un fallo). */
  load(): Promise<void>;
  /** «Sì, confermo» (un pendiente). */
  confirm(): Promise<void>;
  /** «No, grazie» (un pendiente) o «Non voglio più riceverle» (un confirmado). */
  withdraw(): Promise<void>;
}

function errorOf(outcome: Exclude<MarketingOutcome, { kind: "ok" } | { kind: "notFound" }>): PreferencesError {
  return outcome.kind;
}

export function createPreferences(token: string | null, api: MarketingApi, onChange: (state: PreferencesState) => void = () => {}): Preferences {
  let current: PreferencesState = token === null ? { step: "missing" } : { step: "loading" };
  const set = (next: PreferencesState): void => {
    current = next;
    onChange(next);
  };

  async function load(): Promise<void> {
    if (token === null) return;
    if (current.step !== "loading" && current.step !== "failed") return;
    set({ step: "loading" });
    const outcome = await api("status", token);
    if (outcome.kind === "ok") set({ step: outcome.status, email: outcome.email, busy: false, error: null });
    else if (outcome.kind === "notFound") set({ step: "notFound" });
    else set({ step: "failed", error: errorOf(outcome) });
  }

  async function act(route: "confirm" | "withdraw"): Promise<void> {
    const before = current;
    if (token === null || !("busy" in before) || before.busy) return;
    if (route === "confirm" && before.step !== "pending") return;
    if (route === "withdraw" && before.step === "withdrawn") return;
    set({ ...before, busy: true, error: null });
    const outcome = await api(route, token);
    if (outcome.kind === "ok") {
      // La acción no devuelve el email: queda el que se leyó al abrir.
      set({ step: outcome.status, email: before.email, busy: false, error: null });
    } else if (outcome.kind === "notFound") {
      // Venció mientras tanto (un pendiente que pasó los 7 días con la página abierta).
      set({ step: "notFound" });
    } else {
      set({ ...before, busy: false, error: errorOf(outcome) });
    }
  }

  return {
    state: () => current,
    load,
    confirm: () => act("confirm"),
    withdraw: () => act("withdraw"),
  };
}
