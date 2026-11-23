import { describe, expect, it } from "vitest";
import notFoundHtml from "../../404.html?raw";
import indexHtml from "../../index.html?raw";
import reservationHtml from "../../prenotazione/index.html?raw";
import privacyHtml from "../../privacy/index.html?raw";
import requestHtml from "../../richiesta/index.html?raw";
import footerHtml from "../partials/footer.html?raw";
import headerHtml from "../partials/header.html?raw";
import { LIMITS } from "../engine.ts";
import { SHOPPING_SECTIONS } from "../../../supabase/functions/_shared/client_link.ts";
import { ALLERGENS, DIETS } from "../../../supabase/functions/_shared/public_request.ts";
import { DATE_WINDOW, MEAL_OPTIONS, REQUEST_TYPES } from "../request/model.ts";
import { FIELD_ORDER, fieldError } from "../request/validate.ts";
import { LANGS, createI18n, flatten, interpolate, langHref, parseAttrSpec, placeholders, resolveLang, type Lang } from "./core.ts";
import en from "./en.json";
import es from "./es.json";
import itJson from "./it.json";
import { createSiteI18n } from "./site.ts";

const dicts = { it: flatten(itJson), es: flatten(es), en: flatten(en) };
const itKeys = Object.keys(dicts.it).sort();

const htmlFiles = { indexHtml, requestHtml, privacyHtml, reservationHtml, notFoundHtml, headerHtml, footerHtml };

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
    // Las semanas: de 1 a LIMITS.maxWeeks (el check requests_semanas_validas), la 1 marcada, y cada opción
    // dice su número (no es un texto que traducir).
    const weeks = Array.from({ length: LIMITS.maxWeeks }, (_, i) => String(i + 1));
    expect(values("weeks")).toEqual(weeks);
    for (const n of weeks) {
      expect(requestHtml, n).toMatch(new RegExp(`name="weeks" value="${n}"${n === "1" ? " checked" : ""} /><span class="choice__title">${n}</span>`));
    }
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

  it("menù: después de «¿Cuándo?» (la temporada depende de la fecha) y antes de las alergias, con su error y su contador", () => {
    const at = (key: string): number => requestHtml.indexOf(`data-i18n="${key}"`);
    expect(at("request.whenLegend")).toBeLessThan(at("request.menu.legend"));
    expect(at("request.menu.legend")).toBeLessThan(at("request.allergiesLegend"));
    const panel = /<fieldset class="panel" id="menu-panel"[^>]*>([\s\S]*?)<\/fieldset>/.exec(requestHtml)?.[1] ?? "";
    expect(panel).toContain('id="err-menu"');
    expect(panel).toMatch(/<p class="menu__count" id="menu-count" aria-live="polite"/);
    expect(panel).toMatch(/<div [^>]*id="menu-list" role="group" tabindex="-1"/);
  });

  it("los 14 alérgenos y las dietas del contrato tienen su nombre en los tres idiomas", () => {
    for (const lang of LANGS) {
      const keys = [...ALLERGENS.map((a) => `allergens.${a}`), ...DIETS.map((d) => `diets.${d}`)];
      expect(keys.filter((key) => !(key in dicts[lang])), lang).toEqual([]);
      expect(ALLERGENS.length).toBe(14);
    }
  });

  it("página de la clienta: cada sección del súper tiene su nombre en los tres idiomas", () => {
    for (const lang of LANGS) {
      const keys = SHOPPING_SECTIONS.map((section) => `reservation.sections.${section}`);
      expect(keys.filter((key) => !(key in dicts[lang])), lang).toEqual([]);
    }
  });

  it("página de la clienta: el mensaje de cambios pide no escribir datos de salud (SPEC §6), en los tres idiomas", () => {
    const expected: Record<Lang, string> = {
      it: "Non scrivere qui allergie, intolleranze o altri dati sulla salute",
      es: "No escribas aquí alergias, intolerancias ni otros datos de salud",
      en: "Don't write allergies, intolerances or other health information here",
    };
    for (const lang of LANGS) {
      expect(dicts[lang]["reservation.changesHint"], lang).toContain(expected[lang]);
    }
  });

  it("página de la clienta: ningún texto habla de pagos; del precio, solo el recuadro del presupuesto (el servicio)", () => {
    // Este proceso no cambia ni describe nada de pagos (SPEC 5.8): ni cómo ni cuándo se paga.
    const payments =
      /pagament|pagar|\bpago|\bpaga\b|payment|\bpay\b|\bpaid\b|bonifico|transferencia|bank transfer|contanti|efectivo|\bcash\b|tarjeta|carta di credito|credit card|\bcard\b|satispay|stripe|anticipo|adelanto|deposit|caparra/i;
    const prices = /\{(price|amount|total)\w*\}|prezz|precio|price/i;
    for (const lang of LANGS) {
      const texts = Object.entries(dicts[lang]).filter(([key]) => key.startsWith("reservation."));
      expect(texts.length).toBeGreaterThan(50);
      for (const [key, value] of texts) {
        expect(value, `${lang} ${key}`).not.toMatch(payments);
        if (!key.startsWith("reservation.quote.")) expect(value, `${lang} ${key}`).not.toMatch(prices);
        // Los importes los escribe la página con formatCents: ningún texto trae uno.
        expect(value, `${lang} ${key}`).not.toMatch(/€|\d+[.,]\d{2}\b/);
      }
    }
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

describe("sin precios: la web no muestra importes ni tarifas (decisión del 22/11/2026)", () => {
  // Evelyn evalúa a cada cliente y escribe el precio a mano en el presupuesto antes de enviarlo. La fórmula
  // (150 € por semana, 140 € desde 4 semanas) es solo su referencia interna: ningún texto la dice.
  const UNITS: Record<Lang, { weeks: string }> = {
    it: { weeks: "settimane" },
    es: { weeks: "semanas" },
    en: { weeks: "weeks" },
  };
  const NBSP = " ";
  /** Los valores globales de dinero que había: ya no existen, ningún texto los puede pedir. */
  const MONEY_PLACEHOLDERS = /\{(weeklyRate|discountRate|discountWeeks|maxPeople|ex[A-Z]\w*)\}/;
  /** Lo que prometía un cálculo o una estimación del precio. */
  const ESTIMATE_WORDS: Record<Lang, RegExp> = {
    it: /stima|calcol|prezzo|tariff|risparmi/i,
    es: /estimaci|calcul|precio|tarifa|ahorr/i,
    en: /estimate|calculat|price|rate|save|saving/i,
  };

  for (const lang of LANGS) {
    it(`${lang}: ningún texto lleva «€», una tarifa, un valor global de dinero ni promete una estimación`, () => {
      const entries = Object.entries(dicts[lang]);
      // Los textos de privacy hablan de «estimada» solo para la duración del servicio (minutos de cocina, sin dinero).
      const copy = entries.filter(([key]) => !key.startsWith("privacy."));
      for (const [key, value] of entries) {
        expect(value, key).not.toMatch(/€|EUR|&euro;/);
        expect(value, key).not.toMatch(MONEY_PLACEHOLDERS);
      }
      expect(copy.filter(([, value]) => ESTIMATE_WORDS[lang].test(value)).map(([key]) => key)).toEqual([]);
      expect(Object.keys(dicts[lang]).filter((key) => /example|exampleQuote|savings|weeklyService/i.test(key))).toEqual([]);
      expect(Object.keys(dicts[lang]).filter((key) => key.startsWith("request.quote."))).toEqual([]);
    });

    it(`${lang}: sin números escritos a mano; entre el número y la unidad, espacio duro`, () => {
      for (const key of ["landing.faq.aWeeks", "request.weeksHint", "errors.weeks"] as const) {
        const template = dicts[lang][key] ?? "";
        expect(template, key).not.toBe("");
        expect(template, key).not.toMatch(/\d/);
        // "{weeks} settimane": el número no queda solo al final de la línea.
        expect(template, key).not.toMatch(new RegExp(`\} ${UNITS[lang].weeks}`));
      }
      expect(dicts[lang]["landing.faq.aWeeks"]).toContain(`{maxWeeks}${NBSP}${UNITS[lang].weeks}`);
      const i18n = createSiteI18n(lang, dicts[lang], "Radici");
      expect(i18n.t("landing.faq.aWeeks")).toContain(`${LIMITS.maxWeeks}${NBSP}${UNITS[lang].weeks}`);
      // La pista de las semanas ya no habla de descuentos: solo del menú y la sesión de cada semana.
      expect(i18n.t("request.weeksHint")).not.toMatch(/\d/);
    });
  }

  it("la sección «Cómo se paga» es un presupuesto a medida, con una invitación a pedirlo", () => {
    const expected: Record<Lang, { intro: string; title: string; ctaTitle: string; ctaLink: string }> = {
      it: { intro: "Un preventivo su misura, sempre chiaro.", title: "Un preventivo su misura", ctaTitle: "Quanto costerebbe per te?", ctaLink: "Chiedi il tuo preventivo" },
      es: { intro: "Un presupuesto a tu medida, siempre claro.", title: "Un presupuesto a tu medida", ctaTitle: "¿Cuánto sería para ti?", ctaLink: "Pide tu presupuesto" },
      en: { intro: "A quote made for you, always clear.", title: "A quote made for you", ctaTitle: "What would it cost for you?", ctaLink: "Get your quote" },
    };
    for (const lang of LANGS) {
      expect(dicts[lang]["landing.pricing.intro"], lang).toContain(expected[lang].intro);
      expect(dicts[lang]["landing.pricing.serviceTitle"], lang).toBe(expected[lang].title);
      expect(dicts[lang]["landing.pricing.ctaTitle"], lang).toBe(expected[lang].ctaTitle);
      expect(dicts[lang]["landing.pricing.ctaLink"], lang).toBe(expected[lang].ctaLink);
    }
  });

  it("«Nessun abbonamento» pasa a «nessun rinnovo automatico», y sus pares en es y en", () => {
    const expected: Record<Lang, { now: string; before: RegExp }> = {
      it: { now: "Nessun rinnovo automatico, nessun costo nascosto", before: /abbonament/i },
      es: { now: "Sin renovación automática", before: /suscripci/i },
      en: { now: "No automatic renewal", before: /subscription/i },
    };
    for (const lang of LANGS) {
      expect(dicts[lang]["landing.pricing.intro"], lang).toContain(expected[lang].now);
      expect(JSON.stringify(dicts[lang]), lang).not.toMatch(expected[lang].before);
    }
  });

  it("el recuadro «Cómo sigue» tiene los tres pasos y la frase de la compra, en los tres idiomas", () => {
    for (const lang of LANGS) {
      for (const key of ["request.next.title", "request.next.step1", "request.next.step2", "request.next.step3", "request.next.shopping"] as const) {
        expect(dicts[lang][key], `${lang} ${key}`).toBeTruthy();
      }
    }
  });
});

describe("la compra la hace el cliente, con la lista de Evelyn (decisión del 19/11/2026)", () => {
  // Evelyn no hace la compra ni la estima: antes de cada sesión le manda al cliente la lista de ingredientes,
  // con las cantidades. Las frases de referencia son las acordadas para la web, los emails y la app. La
  // privacy también entra desde su versión 2026-11-19, que sacó la compra de las tareas de Evelyn.
  const expected: Record<Lang, { long: string; short: string; before: RegExp }> = {
    it: {
      long: "La spesa la fai tu: prima di ogni sessione Evelyn ti manda la lista degli ingredienti, con le quantità.",
      short: "La spesa la fai tu, con la lista che ti manda Evelyn.",
      before: /scontrin|spesa stimata|fa la spesa|compra tutto|niente spesa|spesa più leggera|tempo per la spesa|spesa a parte|spesa si paga|spesa, al costo/i,
    },
    es: {
      long: "La compra la haces tú: antes de cada sesión Evelyn te manda la lista de ingredientes, con las cantidades.",
      short: "La compra la haces tú, con la lista que te manda Evelyn.",
      before: /ticket|compra estimada|hace la compra|compra todo|sin compras|compra más ligera|tiempo para la compra|compra aparte|compra se paga|precio de coste/i,
    },
    en: {
      long: "You do the shopping: before each session Evelyn sends you the list of ingredients, with quantities.",
      short: "You do the shopping, with the list Evelyn sends you.",
      before: /receipt|grocer|does the shopping|buys everything|no shopping|time to shop|paid separately|at cost/i,
    },
  };

  for (const lang of LANGS) {
    it(`${lang}: la portada, la FAQ del precio y el recuadro del precio lo dicen con las frases de referencia`, () => {
      const text = (key: string): string => dicts[lang][key] ?? "";
      expect(text("landing.included.item2Text")).toBe(expected[lang].long);
      for (const key of ["landing.how.step3Text", "landing.faq.aPrice", "request.next.shopping"]) {
        expect(text(key), key).toContain(expected[lang].short);
      }
    });

    it(`${lang}: ningún texto dice que Evelyn hace la compra, ni habla de tickets ni de compra estimada`, () => {
      const offending = Object.entries(dicts[lang]).filter(([, value]) => expected[lang].before.test(value));
      expect(offending).toEqual([]);
      expect(Object.keys(dicts[lang]).filter((key) => /grocer/i.test(key))).toEqual([]);
    });
  }
});

describe("privacy", () => {
  // 2026-11-19: el menú. Los platos elegidos son datos de la solicitud (y facultativos), y las consultas de
  // GET …/menu entran en el mismo límite por IP que las del calendario, con la misma huella y conservación.
  const menu = { it: "menù", es: "menú", en: "menu" } as const;
  for (const lang of LANGS) {
    it(`${lang}: cuenta el menú (los platos elegidos y sus consultas, en el límite por IP)`, () => {
      for (const key of ["privacy.dataBody", "privacy.legalBody", "privacy.flowBody", "privacy.retentionBody", "privacy.requiredBody"]) {
        expect(dicts[lang][key], key).toContain(menu[lang]);
      }
    });
  }

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

  // 2026-11-22: la página de la reserva (el link de la clienta, contrato client-link). Las respuestas al menú (la
  // confirmación o el mensaje de cambios) son datos de la solicitud; las visitas y respuestas de esa página entran en
  // el límite por IP, con la misma huella y conservación; y el aviso a Evelyn no lleva el mensaje.
  const booking: Record<Lang, { page: string; limit: RegExp; email: string }> = {
    it: { page: "pagina della tua prenotazione", limit: /visite e (le )?risposte nella pagina della prenotazione/, email: "non riporta il tuo messaggio" },
    es: { page: "página de tu reserva", limit: /visitas y respuestas en la página de la reserva/, email: "no incluye tu mensaje" },
    en: { page: "booking page", limit: /visits and replies on the booking page/, email: "doesn't include your message" },
  };
  for (const lang of LANGS) {
    it(`${lang}: cuenta la página de la reserva (respuestas al menú, su límite por IP y el aviso a Evelyn sin el mensaje)`, () => {
      for (const key of ["privacy.metaDescription", "privacy.intro", "privacy.dataBody", "privacy.purposeBody", "privacy.flowBody"]) {
        expect(dicts[lang][key], key).toContain(booking[lang].page);
      }
      for (const key of ["privacy.legalBody", "privacy.flowBody", "privacy.retentionBody"]) {
        expect(dicts[lang][key], key).toMatch(booking[lang].limit);
      }
      expect(dicts[lang]["privacy.flowBody"]).toContain(booking[lang].email);
    });
  }

  // 2026-11-23: el presupuesto en la página de la reserva (SPEC 5.8). La página muestra su precio (la de 2026-11-22
  // decía que nunca mostraba precios) y la clienta lo acepta o lo rechaza: una respuesta más de la solicitud, con la
  // misma base (art. 6.1.b) y la misma conservación que las respuestas al menú. Nada de pagos.
  const quote: Record<Lang, { reply: string; shown: string; before: string }> = {
    it: { reply: "accettare o rifiutare il preventivo", shown: "il preventivo (le date e il prezzo del servizio)", before: "prezzi o allergie" },
    es: { reply: "aceptar o rechazar el presupuesto", shown: "el presupuesto (las fechas y el precio del servicio)", before: "los precios" },
    en: { reply: "accept or decline the quote", shown: "the quote (the dates and the service price)", before: "prices or allergies" },
  };
  const answer: Record<Lang, string> = { it: "preventivo", es: "presupuesto", en: "quote" };
  for (const lang of LANGS) {
    it(`${lang}: cuenta el presupuesto en la página de la reserva (que lo muestra, aceptarlo o rechazarlo, base y conservación)`, () => {
      expect(dicts[lang]["privacy.dataBody"]).toContain(quote[lang].reply);
      expect(dicts[lang]["privacy.flowBody"]).toContain(quote[lang].shown);
      expect(dicts[lang]["privacy.flowBody"], "ya no dice que la página nunca muestra precios").not.toContain(quote[lang].before);
      for (const key of ["privacy.purposeBody", "privacy.legalBody", "privacy.retentionBody", "privacy.requiredBody"]) {
        expect(dicts[lang][key], key).toMatch(new RegExp(answer[lang], "i"));
      }
      for (const key of ["privacy.dataBody", "privacy.purposeBody", "privacy.legalBody", "privacy.flowBody", "privacy.retentionBody"]) {
        expect(dicts[lang][key], key).not.toMatch(/pagament|pagar|\bpago|payment|bonifico|transferencia|contanti|efectivo|\bcash\b/i);
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

  it("langHref: el link de idioma conserva el fragmento (en /prenotazione/, el token del link)", () => {
    expect(langHref("it", "")).toBe("?lang=it");
    expect(langHref("es", "#t=abc")).toBe("?lang=es#t=abc");
    // Como lo resuelve el navegador desde la página de la clienta: la query cambia, el token queda.
    const page = "https://radicicucina.app/prenotazione/?lang=it#t=TOKEN";
    expect(new URL(langHref("en", "#t=TOKEN"), page).href).toBe("https://radicicucina.app/prenotazione/?lang=en#t=TOKEN");
    // Sin el fragmento, un "?lang=en" a secas lo perdería.
    expect(new URL("?lang=en", page).hash).toBe("");
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
