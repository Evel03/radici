// Parte común de todas las páginas: idioma (URL > localStorage > italiano), selector y links internos.
import { config } from "../config.ts";
import { DEFAULT_LANG, isLang, resolveLang, type I18n, type Lang } from "../i18n/core.ts";
import { applyTranslations } from "../i18n/dom.ts";
import { loadDict } from "../i18n/load.ts";
import { createSiteI18n } from "../i18n/site.ts";
import { readStoredLang, storeLang } from "../lib/storage.ts";

type Listener = (i18n: I18n) => void;

export interface Shell {
  readonly i18n: I18n;
  onLanguageChange(listener: Listener): void;
}

interface State {
  /** null mientras no hizo falta cargar textos (página en italiano, que ya viene en el HTML). */
  current: I18n | null;
  readonly listeners: Listener[];
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

async function setup(eager: boolean): Promise<State> {
  const state: State = { current: null, listeners: [] };
  const fromUrl = new URLSearchParams(window.location.search).get("lang")?.toLowerCase();
  if (isLang(fromUrl)) storeLang(fromUrl);

  const lang = resolveLang(window.location.search, readStoredLang());
  if (eager || lang !== document.documentElement.lang) {
    state.current = createSiteI18n(lang, await loadDict(lang), config.brandName);
  }
  render(lang, state.current);

  let latest = 0;
  for (const link of document.querySelectorAll<HTMLAnchorElement>("a[data-lang]")) {
    link.addEventListener("click", (event) => {
      const next = link.dataset["lang"];
      if (!isLang(next)) return;
      event.preventDefault();
      storeLang(next);
      const url = new URL(window.location.href);
      url.searchParams.set("lang", next);
      window.history.replaceState(window.history.state, "", url);
      if (next === document.documentElement.lang) return;

      const request = ++latest;
      void loadDict(next).then((dict) => {
        if (request !== latest) return; // llegó tarde: el usuario ya eligió otro idioma
        const i18n = createSiteI18n(next, dict, config.brandName);
        state.current = i18n;
        render(next, i18n);
        for (const listener of state.listeners) listener(i18n);
      });
    });
  }
  return state;
}

/** Landing y privacy: si la página está en italiano no descarga textos hasta que cambie el idioma. */
export function initLanguage(): void {
  void setup(false);
}

/** Páginas que necesitan textos en tiempo de ejecución (formulario): siempre los carga. */
export async function initShell(): Promise<Shell> {
  const state = await setup(true);
  return {
    get i18n(): I18n {
      if (!state.current) throw new Error("Textos no cargados");
      return state.current;
    },
    onLanguageChange(listener) {
      state.listeners.push(listener);
    },
  };
}
