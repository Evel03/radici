import { describe, expect, it } from "vitest";
import accessHtml from "../../accesso/index.html?raw";
import itDict from "../i18n/it.json";
import type { CommonError, PasswordError, ResendError } from "./flow.ts";
import { STEP_ERRORS, viewOf } from "./view.ts";

// Tipos: cada paso lista TODOS sus errores (si flow.ts suma uno, tsc -b falla hasta agregarlo acá y en el HTML).
type Exact<A, B> = [A] extends [B] ? ([B] extends [A] ? true : false) : false;
const confirmErrors: Exact<(typeof STEP_ERRORS.confirm)[number], CommonError> = true;
const passwordErrors: Exact<(typeof STEP_ERRORS.password)[number], PasswordError> = true;
const resendErrors: Exact<(typeof STEP_ERRORS.expired)[number], ResendError> = true;

describe("viewOf", () => {
  it("missing: solo el paso", () => {
    expect(viewOf({ kind: "missing" })).toMatchObject({ step: "missing", type: null, error: null, busy: false, loginHref: null });
  });

  it("confirm: el tipo de link, ocupado y el error", () => {
    expect(viewOf({ kind: "confirm", type: "recovery", busy: true, error: "network" })).toMatchObject({
      step: "confirm",
      type: "recovery",
      busy: true,
      error: "network",
    });
  });

  it("password: el email enmascarado a la vista y el completo solo para el gestor de contraseñas", () => {
    const view = viewOf({ kind: "password", type: "email", email: "evelyn.rossi@gmail.com", busy: false, error: "tooShort" });
    expect(view).toMatchObject({ step: "password", maskedEmail: "ev•••@g•••.com", username: "evelyn.rossi@gmail.com", error: "tooShort" });
  });

  it("done: el link al login de la app con el email (en el fragmento, no llega a ningún servidor)", () => {
    const view = viewOf({ kind: "done", type: "recovery", email: "ana+cucina@libero.it" });
    expect(view.step).toBe("done");
    expect(view.loginHref).toBe("/app/#/accedi?email=ana%2Bcucina%40libero.it");
    expect(view.maskedEmail).toBeNull();
  });

  it("expired: el motivo, ocupado mientras pide el captcha o el link, y el mensaje neutro al terminar", () => {
    expect(viewOf({ kind: "expired", type: "email", reason: "session", resend: { status: "busy", error: null } })).toMatchObject({
      step: "expired",
      reason: "session",
      busy: true,
      sent: false,
    });
    expect(viewOf({ kind: "expired", type: "email", reason: "link", resend: { status: "sent", error: null } })).toMatchObject({ sent: true, busy: false });
    expect(viewOf({ kind: "expired", type: "email", reason: "link", resend: { status: "idle", error: "captcha" } })).toMatchObject({ error: "captcha" });
  });

  it("los tipos de cada paso están completos", () => {
    expect([confirmErrors, passwordErrors, resendErrors]).toEqual([true, true, true]);
  });
});

describe("el HTML de /accesso/", () => {
  const errorBox: Record<keyof typeof STEP_ERRORS, string> = {
    confirm: "access-confirm-error",
    password: "access-password-error",
    expired: "access-resend-error",
  };

  /** El contenido del elemento con ese id (hasta su cierre, sin anidar el mismo tag). */
  const inner = (id: string): string => {
    const match = new RegExp(`<(\\w+)[^>]*\\bid="${id}"[^>]*>([\\s\\S]*?)</\\1>`).exec(accessHtml);
    if (!match?.[2]) throw new Error(`Falta #${id}`);
    return match[2];
  };

  it("cada error de cada paso tiene su mensaje, con su texto en italiano", () => {
    const texts = (itDict as unknown as { access: { errors: Record<string, string> } }).access.errors;
    for (const [step, keys] of Object.entries(STEP_ERRORS) as Array<[keyof typeof STEP_ERRORS, readonly string[]]>) {
      const box = inner(errorBox[step]);
      const shown = [...box.matchAll(/data-error="(\w+)" data-i18n="access\.errors\.(\w+)"/g)].map((m) => {
        expect(m[1]).toBe(m[2]);
        return m[1];
      });
      expect(shown.sort(), step).toEqual([...keys].sort());
      for (const key of keys) expect(texts[key], key).toBeTruthy();
    }
  });

  it("tiene los elementos que usa pages/accesso.ts", () => {
    for (const id of [
      "access-missing",
      "access-confirm",
      "access-password",
      "access-done",
      "access-expired",
      "access-missing-title",
      "access-confirm-title",
      "access-password-title",
      "access-done-title",
      "access-expired-title",
      "access-confirm-button",
      "access-password-form",
      "access-new-password",
      "access-password-button",
      "access-show-password",
      "access-username",
      "access-masked-email",
      "access-login",
      "access-resend-form",
      "access-resend-email",
      "access-resend-button",
      "access-resend-sent",
      "access-captcha-title",
    ]) {
      expect(accessHtml, id).toContain(`id="${id}"`);
    }
  });

  it("los pasos arrancan ocultos (los muestra el código; sin JavaScript queda el aviso)", () => {
    for (const step of ["missing", "confirm", "password", "done", "expired"]) {
      expect(accessHtml).toMatch(new RegExp(`<section id="access-${step}"[^>]*\\shidden>`));
    }
    expect(accessHtml).toMatch(/<noscript>\s*<p class="notice notice--warn" data-i18n="access\.noscript"><\/p>/);
  });

  it("el formulario de la contraseña: POST (nunca la contraseña en una URL), new-password y el usuario para el gestor", () => {
    expect(accessHtml).toMatch(/<form class="access__form" id="access-password-form" method="post" novalidate>/);
    expect(accessHtml).toMatch(/id="access-new-password"[\s\S]*?type="password"[\s\S]*?autocomplete="new-password"/);
    expect(accessHtml).toMatch(/id="access-username" name="username" type="email" autocomplete="username"/);
    expect(accessHtml).toMatch(/<form class="access__form" id="access-resend-form" method="post" novalidate>/);
  });

  it("no manda el Referer a nadie", () => {
    expect(accessHtml).toContain('<meta name="referrer" content="no-referrer" />');
  });
});

describe("nada se guarda ni se registra", () => {
  const sources = import.meta.glob<string>(["./*.ts", "!./*.test.ts", "../pages/accesso.ts", "../captcha/host.ts"], {
    query: "?raw",
    import: "default",
    eager: true,
  });

  it("ni localStorage, ni sessionStorage, ni cookies, ni IndexedDB, ni la consola", () => {
    expect(Object.keys(sources).length).toBeGreaterThanOrEqual(9);
    for (const [file, source] of Object.entries(sources)) {
      const code = source.replace(/^\s*\/\/.*$/gm, "");
      expect(code, file).not.toMatch(/localStorage|sessionStorage|document\.cookie|indexedDB|console\.|storeLang|lib\/storage/);
    }
  });
});
