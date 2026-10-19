// Carga perezosa de los textos de cada idioma: cada página descarga solo el que usa.
// Los JSON se publican como archivos (assets/<idioma>-<hash>.json, ver assetsInlineLimit en
// vite.config.ts) y se piden con fetch, no con import(): el navegador recuerda un import() fallido
// hasta que se recarga la página (verificado en Chrome 155), mientras que un fetch se puede repetir.
// Si la descarga falla (sin conexión, o un deploy nuevo cambió el hash), el intento sale del caché:
// el próximo pedido de ese idioma lo vuelve a descargar. Quién muestra el aviso: pages/shell.ts.
import { flatten, type Dict, type Lang } from "./core.ts";
import enUrl from "./en.json?url";
import esUrl from "./es.json?url";
import itUrl from "./it.json?url";

/** Una descarga por idioma, que devuelve el JSON ya leído (en los tests, simulada). */
export type DictLoaders = Readonly<Record<Lang, () => Promise<unknown>>>;

/** URL publicada del JSON de cada idioma. */
export const DICT_URLS: Readonly<Record<Lang, string>> = { it: itUrl, es: esUrl, en: enUrl };

async function fetchJson(url: string): Promise<unknown> {
  const response = await fetch(url, { credentials: "same-origin" });
  if (!response.ok) throw new Error(`HTTP ${response.status}: ${url}`);
  return (await response.json()) as unknown;
}

export function createDictLoader(source: DictLoaders): (lang: Lang) => Promise<Dict> {
  const cache = new Map<Lang, Promise<Dict>>();
  return (lang) => {
    const cached = cache.get(lang);
    if (cached) return cached;
    const dict = source[lang]().then((json) => flatten(json));
    cache.set(lang, dict);
    // El rechazo lo maneja quien llamó; acá solo se olvida el intento para poder reintentar.
    dict.catch(() => {
      if (cache.get(lang) === dict) cache.delete(lang);
    });
    return dict;
  };
}

export const loadDict: (lang: Lang) => Promise<Dict> = createDictLoader({
  it: () => fetchJson(DICT_URLS.it),
  es: () => fetchJson(DICT_URLS.es),
  en: () => fetchJson(DICT_URLS.en),
});
