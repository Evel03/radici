// Carga perezosa del JSON de cada idioma: cada página descarga solo el que usa.
import { flatten, type Dict, type Lang } from "./core.ts";

const loaders: Readonly<Record<Lang, () => Promise<{ default: unknown }>>> = {
  it: () => import("./it.json"),
  es: () => import("./es.json"),
  en: () => import("./en.json"),
};

const cache = new Map<Lang, Promise<Dict>>();

export function loadDict(lang: Lang): Promise<Dict> {
  let dict = cache.get(lang);
  if (!dict) {
    dict = loaders[lang]().then((mod) => flatten(mod.default));
    cache.set(lang, dict);
  }
  return dict;
}
