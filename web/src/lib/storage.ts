// localStorage puede fallar (modo privado, navegador interno, datos bloqueados): todo va en try/catch.
const LANG_KEY = "site.lang";

export function readStoredLang(): string | null {
  try {
    return window.localStorage.getItem(LANG_KEY);
  } catch {
    return null;
  }
}

export function storeLang(lang: string): void {
  try {
    window.localStorage.setItem(LANG_KEY, lang);
  } catch {
    // Sin almacenamiento la elección dura solo esta visita (y ?lang= en los links internos).
  }
}
