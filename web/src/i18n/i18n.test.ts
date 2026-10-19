import { describe, expect, it } from "vitest";
import indexHtml from "../../index.html?raw";
import privacyHtml from "../../privacy/index.html?raw";
import requestHtml from "../../richiesta/index.html?raw";
import footerHtml from "../partials/footer.html?raw";
import headerHtml from "../partials/header.html?raw";
import { ALLERGENS, DIETS, MEAL_OPTIONS, REQUEST_TYPES, SLOTS } from "../request/model.ts";
import { FIELD_ORDER } from "../request/validate.ts";
import { createI18n, flatten, interpolate, parseAttrSpec, placeholders, resolveLang } from "./core.ts";
import en from "./en.json";
import es from "./es.json";
import itJson from "./it.json";

const dicts = { it: flatten(itJson), es: flatten(es), en: flatten(en) };
const itKeys = Object.keys(dicts.it).sort();

const htmlFiles = { indexHtml, requestHtml, privacyHtml, headerHtml, footerHtml };

/** Claves que el HTML pide con data-i18n, data-i18n-html y data-i18n-attr. */
function htmlKeys(html: string): string[] {
  const keys = [...html.matchAll(/\sdata-i18n(?:-html)?="([^"]+)"/g)].map((m) => m[1] ?? "");
  for (const m of html.matchAll(/\sdata-i18n-attr="([^"]+)"/g)) {
    keys.push(...parseAttrSpec(m[1] ?? "").map(([, key]) => key));
  }
  return keys;
}

describe("paridad de claves entre idiomas", () => {
  for (const lang of ["es", "en"] as const) {
    it(`${lang}.json tiene exactamente las mismas claves que it.json`, () => {
      const keys = Object.keys(dicts[lang]).sort();
      const missing = itKeys.filter((k) => !(k in dicts[lang]));
      const extra = keys.filter((k) => !(k in dicts.it));
      expect(missing, "faltan").toEqual([]);
      expect(extra, "sobran").toEqual([]);
    });

    it(`${lang}.json usa los mismos marcadores {x} que it.json`, () => {
      for (const key of itKeys) {
        expect(placeholders(dicts[lang][key] ?? ""), key).toEqual(placeholders(dicts.it[key] ?? ""));
      }
    });
  }

  for (const lang of ["it", "es", "en"] as const) {
    it(`${lang}.json no tiene textos vacíos`, () => {
      const empty = Object.entries(dicts[lang]).filter(([, value]) => value.trim() === "");
      expect(empty).toEqual([]);
    });
  }
});

describe("claves usadas por la web", () => {
  it("todas las claves del HTML existen en it.json", () => {
    for (const [file, html] of Object.entries(htmlFiles)) {
      const missing = htmlKeys(html).filter((key) => !(key in dicts.it));
      expect(missing, file).toEqual([]);
    }
  });

  it("existen etiquetas para cada valor del modelo (alérgenos, dietas, tipos, comidas, franjas)", () => {
    const keys = [
      ...ALLERGENS.map((a) => `allergens.${a}`),
      ...DIETS.map((d) => `diets.${d}`),
      ...REQUEST_TYPES.map((t) => `request.type.${t}`),
      ...MEAL_OPTIONS.map((m) => `request.meals.${m}`),
      ...SLOTS.map((s) => `request.slot.${s}`),
    ];
    expect(keys.filter((key) => !(key in dicts.it))).toEqual([]);
  });

  it("el formulario ofrece los 14 alérgenos UE y las dos dietas, en el orden del modelo", () => {
    const values = (name: string): string[] =>
      [...requestHtml.matchAll(new RegExp(`name="${name}" value="([^"]+)"`, "g"))].map((m) => m[1] ?? "");
    expect(values("allergens")).toEqual([...ALLERGENS]);
    expect(ALLERGENS).toHaveLength(14);
    expect(values("diets")).toEqual([...DIETS]);
    expect(values("meals")).toEqual([...MEAL_OPTIONS]);
    expect(values("slot")).toEqual([...SLOTS]);
    expect(values("type")).toEqual([...REQUEST_TYPES]);
  });

  it("cada campo validado tiene su mensaje de error (err-<campo>) en el formulario", () => {
    const missing = FIELD_ORDER.filter((field) => !requestHtml.includes(`id="err-${field}"`));
    expect(missing).toEqual([]);
  });

  it("los HTML no traen texto de UI propio: los elementos traducibles vienen vacíos", () => {
    for (const [file, html] of Object.entries(htmlFiles)) {
      const filled = [...html.matchAll(/<([a-zA-Z][a-zA-Z0-9-]*)\b[^<>]*\sdata-i18n(?:-html)?="[^"]+"[^<>]*>(?!<\/\1>)/g)];
      expect(filled.map((m) => m[0]), file).toEqual([]);
    }
  });
});

describe("núcleo de i18n", () => {
  it("interpola marcadores y deja los desconocidos", () => {
    expect(interpolate("Ciao {name}, {n} {x}", { name: "Eva", n: 2 })).toBe("Ciao Eva, 2 {x}");
  });

  it("resuelve el idioma: URL > guardado > italiano", () => {
    expect(resolveLang("?lang=es", "en")).toBe("es");
    expect(resolveLang("?lang=EN", null)).toBe("en");
    expect(resolveLang("?lang=fr", "en")).toBe("en");
    expect(resolveLang("", "xx")).toBe("it");
    expect(resolveLang("", null)).toBe("it");
  });

  it("createI18n aplica los valores globales y devuelve la clave si falta", () => {
    const i18n = createI18n("es", { hello: "Hola {brand}" }, { brand: "Mestolo" });
    expect(i18n.text("hello")).toBe("Hola Mestolo");
    expect(i18n.text("nope")).toBe("nope");
    expect(i18n.locale).toBe("es-ES");
  });

  it("flatten rechaza valores que no son texto", () => {
    expect(() => flatten({ a: { b: 1 } })).toThrow(TypeError);
  });
});
