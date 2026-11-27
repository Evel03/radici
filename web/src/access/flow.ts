// Los pasos de /accesso/ (docs/contracts/auth.md §11), sin DOM: la página pinta `state` y llama a las acciones.
//   confirm ──«Conferma»──▶ password ──«Salva la password»──▶ done
//      │                       │
//      └── link vencido ──▶ expired ◀── sesión vencida
//                              └──«Reinvia l'email» (con captcha)──▶ mensaje neutro
// - Sin el toque en «Conferma» no se manda nada: un escáner de links que abra la página no gasta el link.
// - El token_hash y el access token viven solo en variables de este módulo, nunca en `state` (que se pinta) ni en
//   ningún almacenamiento. El token_hash se olvida apenas Auth lo contesta; el access token, al cerrar la sesión.
// - Al terminar, la página cierra la sesión: para entrar, la persona usa su email y la contraseña nueva.
import type { AuthApi } from "./api.ts";
import type { AccessLink, LinkRead, LinkType } from "./link.ts";
import { passwordProblem, type PasswordProblem } from "./password.ts";

/** Lo que puede salir mal en cualquier paso. */
export type CommonError = "network" | "rateLimited" | "unavailable";
export type PasswordError = PasswordProblem | "mismatch" | "leaked" | "same" | "weak" | CommonError;
export type ResendError = "email" | "captcha" | CommonError;

export interface ResendState {
  readonly status: "idle" | "busy" | "sent";
  readonly error: ResendError | null;
}

export type AccessState =
  /** La página se abrió sin link, o con uno que no se puede leer. */
  | { readonly kind: "missing" }
  | { readonly kind: "confirm"; readonly type: LinkType; readonly busy: boolean; readonly error: CommonError | null }
  | { readonly kind: "password"; readonly type: LinkType; readonly email: string; readonly busy: boolean; readonly error: PasswordError | null }
  | { readonly kind: "done"; readonly type: LinkType; readonly email: string }
  /** reason "link": el link venció o ya se usó; "session": pasó demasiado tiempo antes de guardar la contraseña. */
  | { readonly kind: "expired"; readonly type: LinkType; readonly reason: "link" | "session"; readonly resend: ResendState };

export interface AccessDeps {
  api: AuthApi;
  /** Un token de captcha nuevo para «Reinvia», o null si no se pudo (src/captcha/host.ts). */
  captchaToken: () => Promise<string | null>;
}

export interface AccessController {
  readonly state: AccessState;
  subscribe(listener: () => void): void;
  /** «Conferma»: canjea el link por una sesión (POST /verify). */
  confirm(): Promise<void>;
  /** «Salva la password»: la guarda (PUT /user) y cierra la sesión. */
  savePassword(password: string, repeat: string): Promise<void>;
  /** «Reinvia l'email»: pide otro link para `email`, con captcha. */
  resend(email: string): Promise<void>;
  /** Llegó otro link con la página abierta (se pegó en la misma pestaña): se empieza de nuevo con ese. */
  openLink(read: LinkRead): void;
}

const IDLE_RESEND: ResendState = { status: "idle", error: null };

/** Un email que vale la pena mandar (la forma la decide Auth; esto evita pedir un captcha por un error de tipeo). */
export function isPlausibleEmail(email: string): boolean {
  return email.length <= 254 && /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email);
}

function initialState(read: LinkRead): { state: AccessState; link: AccessLink | null } {
  switch (read.kind) {
    case "link":
      return { state: { kind: "confirm", type: read.link.type, busy: false, error: null }, link: read.link };
    case "broken":
      return { state: read.type ? { kind: "expired", type: read.type, reason: "link", resend: IDLE_RESEND } : { kind: "missing" }, link: null };
    case "none":
      return { state: { kind: "missing" }, link: null };
  }
}

/** El error de una contraseña que Auth rechazó por débil, según sus razones. */
function weakError(reasons: readonly string[]): PasswordError {
  if (reasons.includes("pwned")) return "leaked";
  if (reasons.includes("length")) return "tooShort";
  if (reasons.includes("characters")) return "lettersDigits";
  return "weak";
}

export function createAccess(read: LinkRead, deps: AccessDeps): AccessController {
  const { api } = deps;
  const listeners: Array<() => void> = [];
  const start = initialState(read);
  let state = start.state;
  let link = start.link;
  let accessToken: string | null = null;
  /** Sube con cada link nuevo: la respuesta de un pedido del link anterior se descarta. */
  let generation = 0;

  const set = (next: AccessState): void => {
    state = next;
    for (const listener of listeners) listener();
  };

  /** Cierra la sesión (si hay una) y la olvida. */
  const endSession = async (): Promise<void> => {
    const token = accessToken;
    accessToken = null;
    if (token) await api.logout(token);
  };

  return {
    get state() {
      return state;
    },

    subscribe(listener) {
      listeners.push(listener);
    },

    async confirm() {
      const current = state;
      if (current.kind !== "confirm" || current.busy || !link) return;
      if (!api.available) {
        set({ ...current, error: "unavailable" });
        return;
      }
      const run = generation;
      const using = link;
      set({ ...current, busy: true, error: null });
      const result = await api.verify(using);
      if (run !== generation) return;
      switch (result.kind) {
        case "ok":
          // El link ya se usó: se olvida. La sesión queda solo acá hasta guardar la contraseña.
          link = null;
          accessToken = result.accessToken;
          set({ kind: "password", type: current.type, email: result.email, busy: false, error: null });
          return;
        case "expired":
          link = null;
          set({ kind: "expired", type: current.type, reason: "link", resend: IDLE_RESEND });
          return;
        case "rateLimited":
          set({ ...current, busy: false, error: "rateLimited" });
          return;
        case "failed":
          set({ ...current, busy: false, error: "network" });
          return;
      }
    },

    async savePassword(password, repeat) {
      const current = state;
      if (current.kind !== "password" || current.busy) return;
      const problem = passwordProblem(password);
      if (problem) {
        set({ ...current, error: problem });
        return;
      }
      // Escrita dos veces: un error de tipeo no deja la cuenta con una contraseña que nadie conoce.
      if (repeat !== password) {
        set({ ...current, error: "mismatch" });
        return;
      }
      const token = accessToken;
      if (!token) {
        set({ kind: "expired", type: current.type, reason: "session", resend: IDLE_RESEND });
        return;
      }
      const run = generation;
      set({ ...current, busy: true, error: null });
      const result = await api.updatePassword(token, password);
      if (run !== generation) return;
      switch (result.kind) {
        case "ok":
          await endSession();
          if (run !== generation) return;
          set({ kind: "done", type: current.type, email: current.email });
          return;
        case "weak":
          set({ ...current, busy: false, error: weakError(result.reasons) });
          return;
        case "same":
          set({ ...current, busy: false, error: "same" });
          return;
        case "session":
          accessToken = null;
          set({ kind: "expired", type: current.type, reason: "session", resend: IDLE_RESEND });
          return;
        case "rateLimited":
          set({ ...current, busy: false, error: "rateLimited" });
          return;
        case "failed":
          set({ ...current, busy: false, error: "network" });
          return;
      }
    },

    async resend(rawEmail) {
      const current = state;
      if (current.kind !== "expired" || current.resend.status === "busy") return;
      const email = rawEmail.trim();
      if (!isPlausibleEmail(email)) {
        set({ ...current, resend: { status: "idle", error: "email" } });
        return;
      }
      if (!api.available) {
        set({ ...current, resend: { status: "idle", error: "unavailable" } });
        return;
      }
      const run = generation;
      set({ ...current, resend: { status: "busy", error: null } });
      const captcha = await deps.captchaToken();
      if (run !== generation) return;
      if (!captcha) {
        set({ ...current, resend: { status: "idle", error: "captcha" } });
        return;
      }
      const result = await api.resend(current.type, email, captcha);
      if (run !== generation) return;
      const error: ResendError | null =
        result.kind === "ok"
          ? null
          : result.kind === "captcha"
            ? "captcha"
            : result.kind === "invalidEmail"
              ? "email"
              : result.kind === "rateLimited"
                ? "rateLimited"
                : "network";
      set({ ...current, resend: { status: error ? "idle" : "sent", error } });
    },

    openLink(next) {
      generation += 1;
      // Una sesión del link anterior (si quedó a medias) se cierra: el link nuevo empieza de cero.
      void endSession();
      const fresh = initialState(next);
      link = fresh.link;
      set(fresh.state);
    },
  };
}
