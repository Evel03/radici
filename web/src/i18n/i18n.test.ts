import { describe, expect, it } from "vitest";
import notFoundHtml from "../../404.html?raw";
import indexHtml from "../../index.html?raw";
import privacyHtml from "../../privacy/index.html?raw";
import requestHtml from "../../richiesta/index.html?raw";
import footerHtml from "../partials/footer.html?raw";
import headerHtml from "../partials/header.html?raw";
import { DATE_WINDOW, MEAL_OPTIONS, REQUEST_TYPES } from "../request/model.ts";
import { FIELD_ORDER, fieldError } from "../request/validate.ts";
import { LANGS, createI18n, flatten, interpolate, parseAttrSpec, placeholders, resolveLang, type Lang } from "./core.ts";
import en from "./en.json";
import es from "./es.json";
import itJson from "./it.json";
import { createSiteI18n } from "./site.ts";

const dicts = { it: flatten(itJson), es: flatten(es), en: flatten(en) };
const itKeys = Object.keys(dicts.it).sort();

const htmlFiles = { indexHtml, requestHtml, privacyHtml, notFoundHtml, headerHtml, footerHtml };

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

  it("existen etiquetas para cada valor del modelo (tipos y comidas)", () => {
    const keys = [...REQUEST_TYPES.map((t) => `request.type.${t}`), ...MEAL_OPTIONS.map((m) => `request.meals.${m}`)];
    expect(keys.filter((key) => !(key in dicts.it))).toEqual([]);
  });

  it("el formulario ofrece las opciones del modelo, en su orden", () => {
    const values = (name: string): string[] =>
      [...requestHtml.matchAll(new RegExp(`name="${name}" value="([^"]+)"`, "g"))].map((m) => m[1] ?? "");
    expect(values("meals")).toEqual([...MEAL_OPTIONS]);
    expect(values("type")).toEqual([...REQUEST_TYPES]);
    // El día se elige en el calendario (con la disponibilidad de Evelyn): ni franja ni selector de fecha nativo.
    expect(requestHtml).not.toContain('name="slot"');
    expect(requestHtml).not.toContain('type="date"');
    expect(requestHtml).toContain('id="calendar-grid"');
  });

  it("pregunta por las alergias: «nadie tiene» o escribirlas con el consentimiento de salud; sin alérgenos ni dietas", () => {
    // Las alergias llegan escritas (restrictionsNote): los alérgenos y las dietas del contrato van vacíos.
    for (const name of ["allergens", "diets"]) {
      expect(requestHtml, name).not.toContain(`name="${name}"`);
    }
    expect(requestHtml).toMatch(/<input id="noAllergies" name="noAllergies" type="checkbox"/);
    // La nota y el consentimiento van juntos en el bloque que se oculta al marcar «nadie tiene».
    const details = /<div id="allergy-details"[^>]*>([\s\S]*?)<\/fieldset>/.exec(requestHtml)?.[1] ?? "";
    expect(details).toMatch(/<textarea [^>]*id="restrictionsNote" name="restrictionsNote"/);
    expect(details).toMatch(/<input id="consentHealth" name="consentHealth" type="checkbox"/);
    // Entre «¿Cuándo?» y «Tus datos».
    const at = (key: string): number => requestHtml.indexOf(`data-i18n="${key}"`);
    expect(at("request.whenLegend")).toBeLessThan(at("request.allergiesLegend"));
    expect(at("request.allergiesLegend")).toBeLessThan(at("request.contactLegend"));
  });

  it("el consentimiento de salud lleva a la sección de salud de la privacy, en los tres idiomas", () => {
    expect(privacyHtml).toContain('id="p-health"');
    for (const lang of LANGS) {
      expect(dicts[lang]["request.healthConsentLabel"], lang).toContain('<a href="/privacy/#p-health">');
    }
  });

  it("alergias: «nadie tiene» nombra la celiaquía; las de otras personas, con su acuerdo; lo escrito fuera del bloque se borra", () => {
    const expected: Record<Lang, { celiac: string; others: string; deleted: string }> = {
      it: { celiac: "celiachia", others: "responsabilità genitoriale", deleted: "senza consenso, le cancelliamo" },
      es: { celiac: "celiaquía", others: "responsabilidad parental", deleted: "sin consentimiento, las borramos" },
      en: { celiac: "coeliac disease", others: "parental responsibility", deleted: "without consent, we delete them" },
    };
    for (const lang of LANGS) {
      const text = (key: string): string => dicts[lang][key] ?? "";
      // La celiaquía no es una alergia ni una intolerancia: sin nombrarla, una casa con un celíaco podría marcar «nadie tiene».
      expect(text("request.noAllergiesLabel"), lang).toContain(expected[lang].celiac);
      expect(text("request.allergiesIntro"), lang).toContain(expected[lang].celiac);
      // El consentimiento del art. 9.2.a es de cada interesado: quien escribe las de otros declara que están de acuerdo.
      expect(text("request.healthConsentLabel"), lang).toContain(expected[lang].others);
      expect(text("privacy.healthBody"), lang).toContain(expected[lang].others);
      // El procedimiento del contrato (§10.2) borra los datos de salud escritos en las notas: la privacy lo promete.
      expect(text("privacy.healthBody"), lang).toContain(expected[lang].deleted);
    }
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

  it("las imágenes no traen texto alternativo propio: del JSON (data-i18n-attr) o alt vacío si son decorativas", () => {
    for (const [file, html] of Object.entries(htmlFiles)) {
      for (const [tag] of html.matchAll(/<img\b[^>]*>/g)) {
        const fromJson = /\sdata-i18n-attr="[^"]*\balt:/.test(tag);
        const alt = /\salt="([^"]*)"/.exec(tag)?.[1];
        // Un alt escrito en el HTML no se traduciría; sin ninguno de los dos, la imagen no tiene texto alternativo.
        if (fromJson) expect(alt, `${file}: ${tag}`).toBeUndefined();
        else expect(alt, `${file}: ${tag}`).toBe("");
      }
    }
  });

  it("no queda ningún link a WhatsApp en la web pública (el pedido va al servidor)", () => {
    const sources = { ...htmlFiles, it: JSON.stringify(itJson), es: JSON.stringify(es), en: JSON.stringify(en) };
    for (const [file, text] of Object.entries(sources)) {
      expect(text, file).not.toMatch(/wa\.me|api\.whatsapp\.com|whatsapp:\/\//i);
    }
  });
});

describe("ventana de la fecha preferida: se dice en semanas", () => {
  // «Hasta dentro de 56 días» se lee mal: los textos dicen «las próximas 8 semanas», con el número
  // calculado del contrato (horizonWeeks en site.ts), nunca escrito a mano. Entre el número y la palabra va
  // un espacio duro (U+00A0): en el teléfono el «8» no queda solo al final de la línea.
  const WINDOW_KEYS = ["request.dateHint", "request.calendar.noneFree", "errors.date"] as const;
  const WEEKS: Record<Lang, string> = { it: "settimane", es: "semanas", en: "weeks" };
  const NBSP = "\u00a0";

  it("la ventana del contrato son semanas enteras", () => {
    expect(DATE_WINDOW.maxDaysAhead % 7).toBe(0);
  });

  for (const lang of LANGS) {
    it(`${lang}: los textos de la ventana usan {horizonWeeks}, sin números escritos a mano`, () => {
      for (const key of WINDOW_KEYS) {
        const template = dicts[lang][key] ?? "";
        expect(placeholders(template), key).toEqual(["horizonWeeks"]);
        expect(template, key).not.toMatch(/\d/);
        expect(template, key).toContain(`{horizonWeeks}${NBSP}${WEEKS[lang]}`);
      }
      // Ningún texto queda con la ventana en días.
      for (const [key, template] of Object.entries(dicts[lang])) {
        expect(placeholders(template), key).not.toContain("horizonDays");
      }
    });

    it(`${lang}: dicen las ${DATE_WINDOW.maxDaysAhead / 7} ${WEEKS[lang]}, también el error de la fecha`, () => {
      const i18n = createSiteI18n(lang, dicts[lang], "Radici");
      const expected = `${DATE_WINDOW.maxDaysAhead / 7}${NBSP}${WEEKS[lang]}`;
      expect(i18n.t("request.dateHint")).toContain(expected);
      expect(i18n.t("request.calendar.noneFree")).toContain(expected);
      const error = fieldError("preferredDate", "dateOutOfRange");
      expect(i18n.t(error.key, error.params)).toContain(expected);
    });
  }
});

describe("privacy", () => {
  // El calendario pide la disponibilidad (GET …/availability, contrato §11) mientras se completa el
  // formulario, antes de enviar, y cada consulta deja la huella (hash) de la IP para su límite. La
  // privacy lo cuenta donde dice qué sale antes del envío, con qué base y cuánto dura la huella.
  const calendar = { it: "calendario", es: "calendario", en: "calendar" } as const;
  for (const lang of LANGS) {
    it(`${lang}: cuenta las consultas del calendario (antes de enviar, base legal y conservación)`, () => {
      for (const key of ["privacy.flowBody", "privacy.legalBody", "privacy.retentionBody"]) {
        expect(dicts[lang][key], key).toContain(calendar[lang]);
      }
    });
  }
});

describe("SEO y accesibilidad de los textos", () => {
  /** Caracteres como los cuenta un buscador (puntos de código, no unidades UTF-16). */
  const length = (text: string): number => [...text].length;

  for (const lang of LANGS) {
    it(`${lang}: títulos ≤ 60 y descripciones ≤ 155 caracteres, con la marca por defecto`, () => {
      const i18n = createI18n(lang, dicts[lang], { brand: "Radici" });
      for (const page of ["landing", "request", "privacy", "notFound"]) {
        const title = i18n.text(`${page}.metaTitle`);
        expect(length(title), title).toBeLessThanOrEqual(60);
      }
      for (const page of ["landing", "request", "privacy"]) {
        const description = i18n.text(`${page}.metaDescription`);
        expect(length(description), description).toBeLessThanOrEqual(155);
      }
    });

    it(`${lang}: el nombre accesible del logotipo empieza con su texto visible, marca y rótulo (WCAG 2.5.3)`, () => {
      const visible = `{brand} · ${dicts[lang]["common.brandTagline"] ?? ""}`;
      expect(dicts[lang]["common.brandTagline"]).toBeTruthy();
      expect(dicts[lang]["common.homeLink"]?.startsWith(visible), dicts[lang]["common.homeLink"]).toBe(true);
    });

    it(`${lang}: el nombre accesible de cada idioma empieza con su texto visible (WCAG 2.5.3)`, () => {
      for (const code of LANGS) {
        const visible = dicts[lang][`common.langCodes.${code}`] ?? "";
        expect(visible).not.toBe("");
        expect(dicts[lang][`common.langLinks.${code}`]).toMatch(new RegExp(`^${visible}\\b`));
      }
    });
  }

  it("los links de idioma usan ese nombre accesible", () => {
    for (const code of LANGS) {
      expect(headerHtml).toContain(`data-i18n="common.langCodes.${code}" data-i18n-attr="aria-label:common.langLinks.${code}"`);
    }
  });

  it("el aviso de carga fallida es una alerta con botón para recargar, oculta hasta que haga falta", () => {
    expect(headerHtml).toMatch(/<div id="load-error" class="load-error" role="alert" hidden>/);
    expect(headerHtml).toMatch(/<p class="load-error__text" data-i18n="common.loadError"><\/p>/);
    expect(headerHtml).toMatch(/<button id="load-error-reload"[^>]*type="button"[^>]*data-i18n="common.reload"><\/button>/);
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
    const i18n = createI18n("es", { hello: "Hola {brand}" }, { brand: "Radici" });
    expect(i18n.text("hello")).toBe("Hola Radici");
    expect(i18n.text("nope")).toBe("nope");
    expect(i18n.locale).toBe("es-ES");
  });

  it("flatten rechaza valores que no son texto", () => {
    expect(() => flatten({ a: { b: 1 } })).toThrow(TypeError);
  });
});
