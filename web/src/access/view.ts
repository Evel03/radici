// Qué muestra /accesso/ para cada estado, sin DOM. Todos los textos ya están en el HTML (data-i18n, del build en
// italiano y traducidos por el selector de idioma); la página solo elige qué sección y qué mensaje se ven, y pone el
// email enmascarado y el link del login. Así funciona aunque no lleguen los textos de otro idioma, y nunca se vuelve a
// pintar el formulario (no se pierde lo escrito ni el cursor).
import type { AccessState, CommonError, PasswordError, ResendError } from "./flow.ts";
import type { LinkType } from "./link.ts";
import { loginHref } from "./login-link.ts";
import { maskEmail } from "./mask.ts";

export type Step = AccessState["kind"];

export interface AccessView {
  readonly step: Step;
  /** El tipo de link: cambia el título y los textos (alta o contraseña). */
  readonly type: LinkType | null;
  /** En «expired»: si venció el link o la sesión. */
  readonly reason: "link" | "session" | null;
  /** Hay un pedido en curso: los botones no hacen nada. */
  readonly busy: boolean;
  /** La clave del mensaje de error a mostrar (access.errors.<clave>), o null. */
  readonly error: string | null;
  /** «Reinvia» terminó bien: se muestra el mensaje neutro. */
  readonly sent: boolean;
  /** El email enmascarado (paso de la contraseña). */
  readonly maskedEmail: string | null;
  /**
   * El email completo para el campo oculto autocomplete="username" del formulario de la contraseña: así el gestor de
   * contraseñas del navegador guarda la contraseña con su cuenta. No se muestra.
   */
  readonly username: string | null;
  readonly loginHref: string | null;
}

export function viewOf(state: AccessState): AccessView {
  const base: AccessView = {
    step: state.kind,
    type: null,
    reason: null,
    busy: false,
    error: null,
    sent: false,
    maskedEmail: null,
    username: null,
    loginHref: null,
  };
  switch (state.kind) {
    case "missing":
      return base;
    case "confirm":
      return { ...base, type: state.type, busy: state.busy, error: state.error };
    case "password":
      return { ...base, type: state.type, busy: state.busy, error: state.error, maskedEmail: maskEmail(state.email), username: state.email };
    case "done":
      return { ...base, type: state.type, loginHref: loginHref(state.email) };
    case "expired":
      return {
        ...base,
        type: state.type,
        reason: state.reason,
        busy: state.resend.status === "busy",
        error: state.resend.error,
        sent: state.resend.status === "sent",
      };
  }
}

/**
 * Los errores que puede dar cada paso (los tipos de flow.ts). Cada uno tiene su texto en access.errors y su elemento
 * en el HTML del paso (data-error): los tests de accesso controlan las dos cosas.
 */
export const STEP_ERRORS = {
  confirm: ["network", "rateLimited", "unavailable"],
  password: ["tooShort", "tooLong", "lettersDigits", "leaked", "same", "weak", "network", "rateLimited", "unavailable"],
  expired: ["email", "captcha", "network", "rateLimited", "unavailable"],
} as const satisfies {
  confirm: readonly CommonError[];
  password: readonly PasswordError[];
  expired: readonly ResendError[];
};
