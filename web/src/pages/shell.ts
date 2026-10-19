// Parte común de todas las páginas: idioma (URL > localStorage > italiano), selector, links internos
// y el aviso si no llegan los textos de un idioma.
import { DEFAULT_LANG, isLang, resolveLang, type I18n, type Lang } from "../i18n/core.ts";
import { applyTranslations } from "../i18n/dom.ts";
import { loadDict } from "../i18n/load.ts";
import { createSiteI18n } from "../i18n/site.ts";
import { readStoredLang, storeLang } from "../lib/storage.ts";
import { config } from "../site-config.ts";

type Listener = (i18n: I18n) => void;

export interface Shell {
  readonly i18n: I18n;
  onLanguageChange(listener: Listener): void;
}

interface State {
  /** null mientras no se cargaron textos (página en italiano, que ya viene en el HTML, o carga fallida). */
  current: I18n | null;
  readonly listeners: Listener[];
}

/** Idioma en que está escrita la página ahora (el HTML llega en italiano desde el build). */
function pageLang(): Lang {
  const lang = document.documentElement.lang;
  return isLang(lang) ? lang : DEFAULT_LANG;
}

function updateLangSwitch(lang: Lang): void {
  for (const link of document.querySelectorAll<HTMLAnchorElement>("a[data-lang]")) {
    if (link.dataset["lang"] === lang) link.setAttribute("aria-current", "true");
    else link.removeAttribute("aria-current");
  }
}

/** Agrega ?lang= a los links internos para no perder el idioma si localStorage no funciona. */
function updateInternalLinks(lang: Lang): void {
  for (const link of document.querySelectorAll<HTMLAnchorElement>('a[href^="/"]:not([data-lang])')) {
    const base = (link.dataset["hrefBase"] ??= link.getAttribute("href") ?? "/");
    if (lang === DEFAULT_LANG) {
      link.setAttribute("href", base);
      continue;
    }
    const url = new URL(base, window.location.origin);
    url.searchParams.set("lang", lang);
    link.setAttribute("href", `${url.pathname}${url.search}${url.hash}`);
  }
}

/** Elementos que solo tienen sentido en algunos idiomas (ej. "el texto vinculante es el italiano"). */
function updateLangOnly(lang: Lang): void {
  for (const el of document.querySelectorAll<HTMLElement>("[data-hide-lang]")) {
    el.hidden = (el.dataset["hideLang"] ?? "").split(" ").includes(lang);
  }
}

function render(lang: Lang, i18n: I18n | null): void {
  const root = document.documentElement;
  // El HTML ya viene en italiano desde el build: solo se reescribe si cambia el idioma.
  if (i18n && root.lang !== lang) {
    applyTranslations(document, i18n);
    root.lang = lang;
  }
  updateLangSwitch(lang);
  updateInternalLinks(lang);
  updateLangOnly(lang);
}

/**
 * No llegaron los textos de un idioma (sin conexión, o un deploy nuevo cambió el archivo): la página no
 * puede quedar muda. Se muestra el aviso del encabezado, que viene del build en italiano (los textos que
 * fallaron son justamente los que faltan), con un botón para recargar. loadDict ya olvidó el intento
 * fallido: elegir el idioma otra vez lo vuelve a descargar.
 */
function showLoadError(): void {
  const box = document.getElementById("load-error");
  if (!box?.hidden) return;
  box.hidden = false;
  // role="alert": el texto se vuelve a insertar con la región ya visible, así lo anuncian también los
  // lectores de pantalla que no avisan cuando aparece una alerta que estaba oculta.
  const message = box.querySelector(".load-error__text");
  if (message) message.replaceWith(message.cloneNode(true));
}

function hideLoadError(): void {
  const box = document.getElementById("load-error");
  if (box) box.hidden = true;
}

/**
 * @param eager la página necesita los textos en tiempo de ejecución (formulario): se cargan siempre.
 * @param onReady se llama la primera vez que hay textos cargados (también si llegan en un reintento).
 */
function setup(eager: boolean, onReady?: () => void): State {
  const state: State = { current: null, listeners: [] };
  const fromUrl = new URLSearchParams(window.location.search).get("lang")?.toLowerCase();
  if (isLang(fromUrl)) storeLang(fromUrl);

  document.getElementById("load-error-reload")?.addEventListener("click", () => window.location.reload());

  let latest = 0;
  const switchTo = (lang: Lang): void => {
    const request = ++latest;
    loadDict(lang).then(
      (dict) => {
        if (request !== latest) return; // llegó tarde: el usuario ya eligió otro idioma
        const first = state.current === null;
        const i18n = createSiteI18n(lang, dict, config.brandName);
        state.current = i18n;
        hideLoadError();
        render(lang, i18n);
        if (first) onReady?.();
        for (const listener of state.listeners) listener(i18n);
      },
      () => {
        if (request !== latest) return;
        showLoadError();
        // La página sigue en el idioma que tenía: el selector lo muestra así.
        updateLangSwitch(pageLang());
      },
    );
  };

  const lang = resolveLang(window.location.search, readStoredLang());
  if (eager || lang !== pageLang()) switchTo(lang);
  else render(lang, null);

  for (const link of document.querySelectorAll<HTMLAnchorElement>("a[data-lang]")) {
    link.addEventListener("click", (event) => {
      const next = link.dataset["lang"];
      if (!isLang(next)) return;
      event.preventDefault();
      storeLang(next);
      const url = new URL(window.location.href);
      url.searchParams.set("lang", next);
      window.history.replaceState(window.history.state, "", url);
      // Ya está en ese idioma y no le faltan textos: se cancela una carga pendiente de otro idioma.
      if (next === pageLang() && (!eager || state.current?.lang === next)) {
        latest += 1;
        hideLoadError();
        render(next, null);
        return;
      }
      switchTo(next);
    });
  }
  return state;
}

/** Landing, privacy y 404: si la página está en italiano no descarga textos hasta que cambie el idioma. */
export function initLanguage(): void {
  setup(false);
}

/**
 * Páginas que necesitan textos en tiempo de ejecución (formulario): se resuelve cuando llegan. Si la
 * primera carga falla, queda el aviso con el botón para recargar; si después un reintento funciona
 * (elegir el idioma otra vez), se resuelve en ese momento y la página arranca igual.
 */
export function initShell(): Promise<Shell> {
  return new Promise((resolve) => {
    const state = setup(true, () => resolve(shell));
    const shell: Shell = {
      get i18n(): I18n {
        if (!state.current) throw new Error("Textos no cargados");
        return state.current;
      },
      onLanguageChange(listener) {
        state.listeners.push(listener);
      },
    };
  });
}
