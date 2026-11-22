// Tests del mensaje con el menú de una semana (menu_message.ts, contrato chef-api.md §13): formatos,
// textos por idioma, escape del HTML y que nunca lleve nada de la clienta. Correr con: npm test.
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  formatQuantity,
  italianDateWithArticle,
  linkPlaceholder,
  renderMenuMessage,
  shoppingGroups,
  type MenuMessageInput,
} from "./menu_message.ts";
import { readMenuSnapshot, type MenuSnapshot } from "./menu_snapshot.ts";
import { LOCALES, type Locale } from "./public_request.ts";
import type { SnapshotQuote } from "./quote_snapshot.ts";

const LINK = "https://radicicucina.app/prenotazione/#t=Tok3n_abc-XYZ";
/** Viernes 20/11/2026, 11:00 en Roma: el lunes 30 (la primera llegada) está a más de 48 horas. */
const NOW = new Date("2026-11-20T10:00:00Z");

function snapshot(locale: Locale = "it", overrides: Partial<MenuSnapshot> = {}): MenuSnapshot {
  return {
    v: 1,
    locale,
    session: { date: "2026-11-30", start: "10:00", week: 1, weeks: 3 },
    weeks: [
      { date: "2026-11-30", start: "10:00" },
      { date: "2026-12-07", start: "10:00" },
      { date: "2027-01-04", start: "10:00" },
    ],
    dishes: [
      {
        name: "Lasagne alla bolognese",
        description: "Pasta all'uovo con ragù.",
        allergens: ["gluten", "eggs", "milk"],
        diet: null,
        portions: 6,
        photo: null,
      },
      { name: "Minestrone", description: null, allergens: [], diet: "vegan", portions: 1, photo: null },
    ],
    items: [
      { name: "Sale", section: "pantry", quantity: null, unit: null },
      { name: "Petto di pollo", section: "meat_fish", quantity: 800, unit: "g" },
      { name: "Zucchine", section: "produce", quantity: 1250, unit: "g" },
      { name: "Latte", section: "dairy_eggs", quantity: 1500, unit: "ml" },
      { name: "Uova", section: "dairy_eggs", quantity: 6, unit: "pcs" },
      { name: "Olio", section: "pantry", quantity: null, unit: null },
      { name: "Pane", section: "bakery", quantity: 1, unit: "pcs" },
    ],
    note: "Tieni pronti 4 contenitori.\n\nGrazie!",
    ...overrides,
  };
}

function input(overrides: Partial<MenuMessageInput> = {}): MenuMessageInput {
  return { brand: "Radici", chefName: "Evelyn", clientName: "Maria Rossi", snapshot: snapshot(), link: LINK, now: NOW, ...overrides };
}

// ---------------------------------------------------------------------------
// Formatos
// ---------------------------------------------------------------------------

test("formatQuantity: g y ml hasta 999; desde 1000, kg y l con coma (it, es) o punto (en), sin ceros de más", () => {
  const cases: Array<[number, "g" | "ml" | "pcs", Locale, string]> = [
    [250, "g", "it", "250 g"],
    [999, "g", "en", "999 g"],
    [1000, "g", "it", "1 kg"],
    [1250, "g", "it", "1,25 kg"],
    [1250, "g", "es", "1,25 kg"],
    [1250, "g", "en", "1.25 kg"],
    [1500, "g", "es", "1,5 kg"],
    [1004, "g", "it", "1 kg"],
    [1005, "g", "it", "1,01 kg"],
    [2999, "g", "it", "3 kg"],
    [12_345, "g", "en", "12.35 kg"],
    [1_000_000, "g", "it", "1.000 kg"],
    [1_000_000, "g", "en", "1,000 kg"],
    [750, "ml", "it", "750 ml"],
    [1500, "ml", "it", "1,5 l"],
    [2000, "ml", "en", "2 l"],
    [1, "pcs", "it", "1 pz"],
    [6, "pcs", "it", "6 pz"],
    [1, "pcs", "es", "1 ud."],
    [6, "pcs", "es", "6 uds."],
    [1, "pcs", "en", "1 pc"],
    [6, "pcs", "en", "6 pcs"],
    [1200, "pcs", "it", "1.200 pz"],
  ];
  for (const [quantity, unit, locale, expected] of cases) {
    assert.equal(formatQuantity(quantity, unit, locale), expected, `${quantity} ${unit} ${locale}`);
  }
});

test("shoppingGroups: por sección en el orden del súper, lo q.b. al final; secciones vacías no salen", () => {
  assert.deepEqual(shoppingGroups(snapshot().items, "it"), [
    { title: "Frutta e verdura", lines: [{ name: "Zucchine", quantity: "1,25 kg" }] },
    { title: "Carne e pesce", lines: [{ name: "Petto di pollo", quantity: "800 g" }] },
    {
      title: "Latticini e uova",
      lines: [
        { name: "Latte", quantity: "1,5 l" },
        { name: "Uova", quantity: "6 pz" },
      ],
    },
    { title: "Panetteria", lines: [{ name: "Pane", quantity: "1 pz" }] },
    {
      title: "Da avere in casa",
      lines: [
        { name: "Sale", quantity: null },
        { name: "Olio", quantity: null },
      ],
    },
  ]);
  assert.deepEqual(
    shoppingGroups(snapshot().items, "es").map((group) => group.title),
    ["Fruta y verdura", "Carne y pescado", "Lácteos y huevos", "Panadería", "Para tener en casa"],
  );
  assert.deepEqual(
    shoppingGroups(snapshot().items, "en").map((group) => group.title),
    ["Fruit and veg", "Meat and fish", "Dairy and eggs", "Bakery", "To have at home"],
  );
  assert.deepEqual(shoppingGroups([], "it"), []);
});

// ---------------------------------------------------------------------------
// El mensaje
// ---------------------------------------------------------------------------

test("italiano, semana 1 de 3: asunto, saludo, semana, día, llegada y todas las fechas; platos, lista, nota y link", () => {
  const message = renderMenuMessage(input());
  assert.equal(message.subject, "Radici: il menù della settimana 1 di 3 (30 nov)");
  for (const expected of [
    "Ciao Maria!",
    "Evelyn ha preparato il menù della settimana 1 di 3: arriva da te lunedì 30 novembre 2026 alle 10:00.",
    "Settimana: 1 di 3",
    "Giorno: lunedì 30 novembre 2026",
    "Arrivo: 10:00",
    "Tutte le date: 30 nov · 7 dic · 4 gen 2027",
    "• Lasagne alla bolognese\n  Pasta all'uovo con ragù.\n  6 porzioni\n  Allergeni: glutine, uova, latte e derivati",
    "• Minestrone\n  1 porzione · Vegano\n  Nessuno dei 14 allergeni principali",
    "LA SPESA\nLa spesa la fai tu: tieni tutto pronto per quando arriva Evelyn.",
    "Frutta e verdura\n• Zucchine: 1,25 kg",
    "Latticini e uova\n• Latte: 1,5 l\n• Uova: 6 pz",
    "Da avere in casa\n• Sale\n• Olio",
    "UNA NOTA DI EVELYN\nTieni pronti 4 contenitori.\nGrazie!",
    `Vedi e conferma il menù: ${LINK}`,
    "Hai domande? Rispondi a questa email.",
    "Cucina autentica, a casa tua.",
  ]) {
    assert.ok(message.text.includes(expected), `falta en el texto: ${expected}\n${message.text}`);
  }
  // Las secciones en el orden del súper; lo q.b., al final.
  const order = ["Frutta e verdura", "Carne e pesce", "Latticini e uova", "Panetteria", "Da avere in casa"].map((title) => message.text.indexOf(title));
  assert.deepEqual([...order].sort((a, b) => a - b), order);
  assert.ok(!message.text.includes(linkPlaceholder("it")));
});

test("el HTML: el diseño compartido, en el idioma de la clienta, con el botón al link y la nota en párrafos", () => {
  const { html } = renderMenuMessage(input());
  assert.match(html, /^<!doctype html><html lang="it">/);
  assert.ok(html.includes("<title>Radici: il menù della settimana 1 di 3 (30 nov)</title>"));
  assert.ok(html.includes("Evelyn arriva il 30 nov alle 10:00: guarda il menù e confermalo."), "el preheader");
  assert.ok(html.includes(`href="${LINK}"`));
  assert.ok(html.includes(">Vedi e conferma il menù</a>"));
  assert.ok(html.includes("30&nbsp;nov&nbsp;· 7&nbsp;dic&nbsp;· 4&nbsp;gen&nbsp;2027"), "las fechas no se cortan por la mitad");
  assert.ok(html.includes("Pasta all&#39;uovo con ragù.<br>6 porzioni<br>Allergeni: glutine, uova, latte e derivati"));
  assert.ok(html.includes("Latte: 1,5 l<br>Uova: 6 pz"));
  assert.ok(html.includes(">Tieni pronti 4 contenitori.</p>") && html.includes(">Grazie!</p>"), "un párrafo por línea de la nota");
  assert.ok(!/<img\b/i.test(html), "sin imágenes remotas");
});

test("semana 2 de 3: sin la lista de fechas; reserva de una semana: sin semana ni fechas, otro asunto", () => {
  const second = renderMenuMessage(input({ snapshot: snapshot("it", { session: { date: "2026-12-07", start: "10:00", week: 2, weeks: 3 } }) }));
  assert.equal(second.subject, "Radici: il menù della settimana 2 di 3 (7 dic)");
  assert.ok(!second.text.includes("Tutte le date"));
  assert.ok(!second.whatsapp.includes("Tutte le date"));
  assert.ok(second.text.includes("Settimana: 2 di 3"));

  const single = renderMenuMessage(
    input({ snapshot: snapshot("it", { session: { date: "2026-11-30", start: "11:30", week: 1, weeks: 1 }, weeks: [{ date: "2026-11-30", start: "11:30" }] }) }),
  );
  assert.equal(single.subject, "Radici: il tuo menù del 30 nov");
  assert.ok(single.text.includes("Evelyn ha preparato il tuo menù: arriva da te lunedì 30 novembre 2026 alle 11:30."));
  assert.ok(!single.text.includes("Settimana:"));
  assert.ok(!single.text.includes("Tutte le date"));
});

test("las fechas de la reserva llevan la hora de cada semana si alguna llega a otra hora", () => {
  const message = renderMenuMessage(
    input({
      snapshot: snapshot("it", {
        weeks: [
          { date: "2026-11-30", start: "10:00" },
          { date: "2026-12-07", start: "11:30" },
        ],
        session: { date: "2026-11-30", start: "10:00", week: 1, weeks: 2 },
      }),
    }),
  );
  assert.ok(message.text.includes("Tutte le date: 30 nov 10:00 · 7 dic 11:30"));
});

test("vista previa (sin link): el texto de reemplazo en el email y en el WhatsApp, nunca un link", () => {
  for (const locale of LOCALES) {
    const message = renderMenuMessage(input({ snapshot: snapshot(locale), link: null }));
    const placeholder = linkPlaceholder(locale);
    assert.ok(message.text.includes(placeholder), locale);
    assert.ok(message.whatsapp.includes(placeholder), locale);
    assert.ok(message.html.includes(placeholder), locale);
    for (const text of [message.text, message.whatsapp, message.html]) {
      assert.ok(!text.includes("/prenotazione/"), `${locale}: sin link`);
      assert.ok(!text.includes("#t="), `${locale}: sin token`);
    }
  }
  assert.equal(linkPlaceholder("it"), "[link personale per confermare]");
  assert.equal(linkPlaceholder("es"), "[enlace personal para confirmar]");
  assert.equal(linkPlaceholder("en"), "[personal link to confirm]");
});

test("español e inglés: los mismos datos con sus textos, sus nombres de alérgenos y sus números", () => {
  const es = renderMenuMessage(input({ snapshot: snapshot("es") }));
  assert.equal(es.subject, "Radici: el menú de la semana 1 de 3 (30 nov)");
  for (const expected of [
    "¡Hola, Maria!",
    "Evelyn ha preparado el menú de la semana 1 de 3: llega a tu casa el lunes, 30 de noviembre de 2026 a las 10:00.",
    "Todas las fechas: 30 nov · 7 dic · 4 ene 2027",
    "  6 porciones\n  Alérgenos: gluten, huevos, leche y lácteos",
    "  1 porción · Vegano\n  Ninguno de los 14 alérgenos principales",
    "La compra la haces tú: tenlo todo listo para cuando llegue Evelyn.",
    "Fruta y verdura\n• Zucchine: 1,25 kg",
    "• Uova: 6 uds.",
    "Para tener en casa\n• Sale\n• Olio",
    "UNA NOTA DE EVELYN",
    `Ver y confirmar el menú: ${LINK}`,
    "¿Tienes dudas? Responde a este email.",
  ]) {
    assert.ok(es.text.includes(expected), `es: ${expected}\n${es.text}`);
  }
  assert.match(es.html, /<html lang="es">/);

  const en = renderMenuMessage(input({ snapshot: snapshot("en") }));
  assert.equal(en.subject, "Radici: your menu for week 1 of 3 (30 Nov)");
  for (const expected of [
    "Hi Maria!",
    "Evelyn has prepared the menu for week 1 of 3 and will arrive at your home on Monday 30 November 2026 at 10:00.",
    "All dates: 30 Nov · 7 Dec · 4 Jan 2027",
    "  6 portions\n  Allergens: gluten, eggs, milk and dairy",
    "  1 portion · Vegan\n  None of the 14 major allergens",
    "Fruit and veg\n• Zucchine: 1.25 kg",
    "• Latte: 1.5 l",
    "• Uova: 6 pcs",
    "To have at home\n• Sale\n• Olio",
    "A NOTE FROM EVELYN",
    `See and confirm the menu: ${LINK}`,
    "Any questions? Just reply to this email.",
  ]) {
    assert.ok(en.text.includes(expected), `en: ${expected}\n${en.text}`);
  }
});

test("los 14 alérgenos tienen nombre en los tres idiomas (como la web)", () => {
  const all = ["gluten", "crustaceans", "eggs", "fish", "peanuts", "soy", "milk", "nuts", "celery", "mustard", "sesame", "sulphites", "lupin", "molluscs"] as const;
  const expected: Record<Locale, string> = {
    it: "Allergeni: glutine, crostacei, uova, pesce, arachidi, soia, latte e derivati, frutta a guscio, sedano, senape, sesamo, solfiti, lupini, molluschi",
    es: "Alérgenos: gluten, crustáceos, huevos, pescado, cacahuetes (maní), soja, leche y lácteos, frutos de cáscara, apio, mostaza, sésamo, sulfitos, altramuces, moluscos",
    en: "Allergens: gluten, crustaceans, eggs, fish, peanuts, soya, milk and dairy, tree nuts, celery, mustard, sesame, sulphites, lupin, molluscs",
  };
  for (const locale of LOCALES) {
    const base = snapshot(locale);
    const message = renderMenuMessage(input({ snapshot: { ...base, dishes: [{ ...base.dishes[0]!, allergens: [...all] }] } }));
    assert.ok(message.text.includes(expected[locale]), locale);
  }
});

test("WhatsApp: compacto, con *negrita* y _cursiva_, sin HTML; un plato en dos renglones", () => {
  const { whatsapp } = renderMenuMessage(input());
  assert.ok(whatsapp.startsWith("Ciao Maria!\nEvelyn ha preparato il menù della settimana 1 di 3"));
  for (const expected of [
    "*Tutte le date:* 30 nov · 7 dic · 4 gen 2027",
    "*Il menù*\n• *Lasagne alla bolognese* — Pasta all'uovo con ragù.\n  6 porzioni · Allergeni: glutine, uova, latte e derivati\n• *Minestrone*\n  1 porzione · Vegano · Nessuno dei 14 allergeni principali",
    "*La spesa*\nLa spesa la fai tu: tieni tutto pronto per quando arriva Evelyn.\n_Frutta e verdura_\n• Zucchine: 1,25 kg",
    "_Da avere in casa_\n• Sale\n• Olio",
    "*Una nota di Evelyn*\nTieni pronti 4 contenitori.\nGrazie!",
    `${LINK}\n\nHai domande? Rispondi a questo messaggio.`,
  ]) {
    assert.ok(whatsapp.includes(expected), `falta: ${expected}\n${whatsapp}`);
  }
  assert.ok(!/[<>]/.test(whatsapp), "sin etiquetas");
  assert.ok(!whatsapp.includes("\n\n\n"));
});

test("sin lista ni nota: sin esas secciones", () => {
  const message = renderMenuMessage(input({ snapshot: snapshot("it", { items: [], note: null }) }));
  for (const text of [message.text, message.whatsapp, message.html]) {
    assert.ok(!/la spesa/i.test(text));
    assert.ok(!/una nota di/i.test(text));
  }
});

test("del nombre, solo el de pila si parece un nombre: nunca un email, un teléfono ni un link escritos en el formulario", () => {
  const greeting = (clientName: string | null): string => renderMenuMessage(input({ clientName })).text.split("\n")[0] ?? "";
  assert.equal(greeting("Maria Rossi"), "Ciao Maria!");
  assert.equal(greeting("D'Angelo"), "Ciao D'Angelo!");
  for (const name of ["maria@example.test", "https://bit.ly/x", "www.example.com", "+39 333 1234567", "", null]) {
    const message = renderMenuMessage(input({ clientName: name }));
    assert.equal(message.text.split("\n")[0], "Ciao!", String(name));
    if (name) {
      for (const text of [message.text, message.whatsapp, message.html, message.subject]) {
        assert.ok(!text.includes(name), `${name} aparece`);
      }
    }
  }
});

test("HTML: todo el texto se escapa (platos, lista, nota y nombre de la cocinera)", () => {
  const base = snapshot();
  const evil = '<script>alert("x")</script>';
  const message = renderMenuMessage(
    input({
      chefName: "Eve <b>lyn</b>",
      snapshot: {
        ...base,
        dishes: [{ ...base.dishes[0]!, name: `Torta & "Co" ${evil}`, description: `Con <img src=x onerror=alert(1)>` }],
        items: [{ name: `Pane ${evil}`, section: "bakery", quantity: 2, unit: "pcs" }],
        note: `Nota ${evil}\n<a href="https://evil.test">clic</a>`,
      },
    }),
  );
  assert.ok(!message.html.includes("<script>"));
  assert.ok(!message.html.includes("<img"));
  assert.ok(!message.html.includes('<a href="https://evil.test"'));
  assert.ok(!message.html.includes("<b>lyn"));
  assert.ok(message.html.includes("Torta &amp; &quot;Co&quot; &lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt;"));
  assert.ok(message.html.includes("Pane &lt;script&gt;"));
  assert.ok(message.html.includes("Eve &lt;b&gt;lyn&lt;/b&gt;"));
});

test("nunca lleva la dirección, el contacto, las alergias de la clienta ni precios, aunque la foto los trajera", () => {
  const raw = {
    ...snapshot(),
    address: "Via Segretissima 42",
    restrictions: "celiachia grave",
    contact: { email: "maria.pii@example.test", phone: "+393337654321" },
    serviceCents: 14000,
    price: "140,00 €",
  };
  const read = readMenuSnapshot(raw);
  assert.ok(read);
  const message = renderMenuMessage(input({ snapshot: read }));
  for (const text of [message.subject, message.text, message.whatsapp, message.html]) {
    for (const marker of ["Segretissima", "celiachia", "maria.pii", "3337654321", "14000", "140,00", "€"]) {
      assert.ok(!text.includes(marker), `aparece ${marker}`);
    }
  }
});

test("italiano: el artículo delante de una fecha con elisión («l'8», «dell'11») y «il 1°»", () => {
  assert.equal(italianDateWithArticle("il", "30 nov"), "il 30 nov");
  assert.equal(italianDateWithArticle("del", "30 nov"), "del 30 nov");
  assert.equal(italianDateWithArticle("il", "8 dic"), "l'8 dic");
  assert.equal(italianDateWithArticle("del", "8 dic"), "dell'8 dic");
  assert.equal(italianDateWithArticle("il", "11 gen"), "l'11 gen");
  assert.equal(italianDateWithArticle("del", "11 gen"), "dell'11 gen");
  assert.equal(italianDateWithArticle("il", "1 dic"), "il 1° dic");
  assert.equal(italianDateWithArticle("del", "1 dic"), "del 1° dic");
  assert.equal(italianDateWithArticle("il", "18 dic"), "il 18 dic", "diciotto empieza con consonante");
  assert.equal(italianDateWithArticle("il", "10 dic"), "il 10 dic");

  const week = (date: string) =>
    renderMenuMessage(input({ snapshot: snapshot("it", { session: { date, start: "10:00", week: 1, weeks: 1 }, weeks: [{ date, start: "10:00" }] }) }));
  const cases: Array<[string, string, string]> = [
    ["2026-12-08", "Radici: il tuo menù dell'8 dic", "Evelyn arriva l&#39;8 dic alle 10:00"],
    ["2027-01-11", "Radici: il tuo menù dell'11 gen", "Evelyn arriva l&#39;11 gen alle 10:00"],
    ["2026-12-01", "Radici: il tuo menù del 1° dic", "Evelyn arriva il 1° dic alle 10:00"],
    ["2026-12-18", "Radici: il tuo menù del 18 dic", "Evelyn arriva il 18 dic alle 10:00"],
  ];
  for (const [date, subject, preheader] of cases) {
    const message = week(date);
    assert.equal(message.subject, subject, date);
    assert.ok(message.html.includes(preheader), `${date}: ${preheader}`);
    for (const wrong of ["del 8", "il 8", "del 11", "il 11", "il 1 dic", "del 1 dic"]) {
      assert.ok(!message.subject.includes(wrong) && !message.html.includes(wrong), `${date}: ${wrong}`);
    }
  }
  // Con varias semanas la fecha del asunto va entre paréntesis, sin artículo; en español y en inglés no hay elisión.
  const several = renderMenuMessage(input({ snapshot: snapshot("it", { session: { date: "2026-12-08", start: "10:00", week: 1, weeks: 3 } }) }));
  assert.equal(several.subject, "Radici: il menù della settimana 1 di 3 (8 dic)");
  const es = renderMenuMessage(
    input({ snapshot: snapshot("es", { session: { date: "2026-12-08", start: "10:00", week: 1, weeks: 1 }, weeks: [{ date: "2026-12-08", start: "10:00" }] }) }),
  );
  assert.equal(es.subject, "Radici: tu menú del 8 dic");
});

test("la nota: una palabra larga (un link) se parte y no ensancha el email en el teléfono", () => {
  const url = "https://www.esselunga.it/commerce/nav/supermercato/store/ricerca/lievito%20di%20birra%20fresco";
  const { html } = renderMenuMessage(input({ snapshot: snapshot("it", { note: `Compra il lievito qui: ${url}` }) }));
  const paragraph = html.split("<p ").find((part) => part.includes("Compra il lievito qui"));
  assert.ok(paragraph, "la nota va en un párrafo");
  assert.ok(paragraph.startsWith('style="') && paragraph.includes("word-break:break-word;overflow-wrap:anywhere;"), paragraph);
  assert.ok(paragraph.includes(`Compra il lievito qui: ${url}</p>`));
});

// ---------------------------------------------------------------------------
// Con el presupuesto (la semana 1 de un presupuesto abierto, SPEC 5.8)
// ---------------------------------------------------------------------------

/** El presupuesto de 4 semanas a 140 € (560 €), con la primera llegada el lunes 30/11 a las 10:00. */
function quote(overrides: Partial<SnapshotQuote> = {}): SnapshotQuote {
  return {
    version: 1,
    totalCents: 56000,
    weeks: [
      { date: "2026-11-30", start: "10:00", serviceCents: 14000 },
      { date: "2026-12-07", start: "10:00", serviceCents: 14000 },
      { date: "2026-12-14", start: "10:00", serviceCents: 14000 },
      { date: "2026-12-21", start: "11:30", serviceCents: 14000 },
    ],
    holdHours: 48,
    firstStart: "2026-11-30T10:00",
    ...overrides,
  };
}

function quoteSnapshot(locale: Locale = "it", value: SnapshotQuote = quote()): MenuSnapshot {
  return snapshot(locale, {
    session: { date: "2026-11-30", start: "10:00", week: 1, weeks: value.weeks.length },
    weeks: value.weeks.map((week) => ({ date: week.date, start: week.start })),
    quote: value,
  });
}

/** Palabras de pagos (cómo o cuándo se paga): ningún mensaje las lleva. */
const PAYMENT_WORDS =
  /pagament|pagar|\bpago|\bpaga\b|bonifico|transferencia|bank transfer|contanti|efectivo|\bcash\b|tarjeta|carta di credito|credit card|\bcard\b|stripe|satispay|payment|\bpay\b|\bpaid\b|anticipo|adelanto|deposit|caparra|señal/i;

test("italiano con el presupuesto: las semanas con su llegada, el precio del servicio, 48 horas y que se acepta desde el link", () => {
  const message = renderMenuMessage(input({ snapshot: quoteSnapshot() }));
  assert.equal(message.subject, "Radici: il tuo preventivo e il menù del 30 nov");
  for (const expected of [
    "Ciao Maria!\n\nEvelyn ha preparato il preventivo per le tue 4 settimane e il menù della prima.",
    "IL PREVENTIVO\nEcco il preventivo per le tue 4 settimane:\n" +
      "Settimana 1: lunedì 30 novembre 2026, arrivo alle 10:00\n" +
      "Settimana 2: lunedì 7 dicembre 2026, arrivo alle 10:00\n" +
      "Settimana 3: lunedì 14 dicembre 2026, arrivo alle 10:00\n" +
      "Settimana 4: lunedì 21 dicembre 2026, arrivo alle 11:30\n" +
      "Prezzo del servizio: 560,00 € in totale (140,00 € a settimana)\n" +
      "Accettalo entro 48 ore. Fino ad allora, queste date restano riservate per te.\n" +
      "Dal tuo link puoi accettare il preventivo e il menù della prima settimana, chiedere dei cambi o rifiutarlo.",
    "QUANDO\nSettimana: 1 di 4\nGiorno: lunedì 30 novembre 2026\nArrivo: 10:00",
    "Apri il tuo link per vedere il preventivo e il menù completo, con le foto dei piatti, e accettarli.",
    `Vedi e accetta il preventivo: ${LINK}`,
  ]) {
    assert.ok(message.text.includes(expected), `falta en el texto: ${expected}\n${message.text}`);
  }
  // Las fechas van en el presupuesto, con la llegada de cada una: sin «Tutte le date».
  assert.ok(!message.text.includes("Tutte le date"));
  assert.ok(!message.whatsapp.includes("Tutte le date"));
  // El presupuesto va antes del menú.
  assert.ok(message.text.indexOf("IL PREVENTIVO") < message.text.indexOf("IL MENÙ"));

  assert.ok(message.html.includes("<strong>560,00&nbsp;€ in totale (140,00&nbsp;€ a settimana)</strong>"), "el precio, destacado y sin cortarse");
  assert.ok(message.html.includes(">Vedi e accetta il preventivo</a>"));
  assert.ok(message.html.includes("Evelyn ti ha mandato il preventivo: guardalo e accettalo dal tuo link."), "el preheader");
  assert.ok(!message.html.includes("Vedi e conferma il menù"));

  for (const expected of [
    "*Il preventivo*\nEcco il preventivo per le tue 4 settimane:\n• Settimana 1: lunedì 30 novembre 2026, arrivo alle 10:00",
    "• Settimana 4: lunedì 21 dicembre 2026, arrivo alle 11:30\n*Prezzo del servizio:* 560,00 € in totale (140,00 € a settimana)\nAccettalo entro 48 ore.",
    "Apri il tuo link per vedere il preventivo e il menù completo, con le foto dei piatti, e accettarli. Se vuoi cambiare qualcosa, puoi chiederlo da lì; puoi anche rifiutare il preventivo.\n" +
      LINK,
  ]) {
    assert.ok(message.whatsapp.includes(expected), `falta en el WhatsApp: ${expected}\n${message.whatsapp}`);
  }
});

test("el plazo: si la primera llegada es antes de las 48 horas, «prima di <día>, alle <hora>» (nunca después de la llegada)", () => {
  // Sábado 28/11 a las 20:00 en Roma: el lunes a las 10:00 está a 38 horas.
  const late = new Date("2026-11-28T19:00:00Z");
  const expected: Record<Locale, string> = {
    it: "Accettalo prima di lunedì 30 novembre 2026, alle 10:00. Fino ad allora, queste date restano riservate per te.",
    es: "Acéptalo antes del lunes, 30 de noviembre de 2026, a las 10:00. Hasta entonces, estas fechas quedan reservadas para ti.",
    en: "Please accept it before Monday 30 November 2026 at 10:00. Until then, these dates are held for you.",
  };
  for (const locale of LOCALES) {
    const message = renderMenuMessage(input({ snapshot: quoteSnapshot(locale), now: late }));
    for (const text of [message.text, message.whatsapp]) assert.ok(text.includes(expected[locale]), `${locale}: ${text}`);
    assert.ok(!/48/.test(message.text), `${locale}: sin las 48 horas`);
  }
  // Con otro plazo de la cocinera, sus horas.
  const short = renderMenuMessage(input({ snapshot: quoteSnapshot("it", quote({ holdHours: 24 })), now: late }));
  assert.ok(short.text.includes("Accettalo entro 24 ore."));
  const one = renderMenuMessage(input({ snapshot: quoteSnapshot("en", quote({ holdHours: 1 })), now: late }));
  assert.ok(one.text.includes("Please accept it within 1 hour."));
});

test("semanas a distinto precio: cada una con el suyo y el total; una sola semana: el precio y su día", () => {
  const uneven = quote({
    totalCents: 30001,
    weeks: [
      { date: "2026-11-30", start: "10:00", serviceCents: 15001 },
      { date: "2026-12-07", start: "10:00", serviceCents: 15000 },
    ],
  });
  const message = renderMenuMessage(input({ snapshot: quoteSnapshot("it", uneven) }));
  for (const expected of [
    "Settimana 1: lunedì 30 novembre 2026, arrivo alle 10:00 · 150,01 €",
    "Settimana 2: lunedì 7 dicembre 2026, arrivo alle 10:00 · 150,00 €",
    "Prezzo del servizio: 300,01 € in totale",
  ]) {
    assert.ok(message.text.includes(expected), `falta: ${expected}\n${message.text}`);
  }
  assert.ok(!message.text.includes("€ a settimana"), "sin un precio por semana que no es el de todas");
  assert.ok(message.html.includes("arrivo alle 10:00 · 150,01&nbsp;€"));

  const single = quote({ totalCents: 15000, weeks: [{ date: "2026-11-30", start: "10:00", serviceCents: 15000 }] });
  const one = renderMenuMessage(input({ snapshot: quoteSnapshot("it", single) }));
  for (const expected of [
    "Evelyn ha preparato il preventivo e il tuo menù.",
    "IL PREVENTIVO\nEcco il preventivo:\nQuando: lunedì 30 novembre 2026, arrivo alle 10:00\nPrezzo del servizio: 150,00 €\n",
    "Dal tuo link puoi accettare il preventivo e il menù, chiedere dei cambi o rifiutarlo.",
  ]) {
    assert.ok(one.text.includes(expected), `falta: ${expected}\n${one.text}`);
  }
  assert.ok(!one.text.includes("Settimana"), "una sola semana: ni «Settimana 1» ni «1 di 1»");
});

test("un reenvío (versión 2 o más): el asunto y el texto dicen que es el presupuesto actualizado", () => {
  const expected: Record<Locale, { subject: string; lead: string }> = {
    it: { subject: "Radici: il preventivo aggiornato e il menù del 30 nov", lead: "Ecco il preventivo aggiornato per le tue 4 settimane:" },
    es: { subject: "Radici: tu presupuesto actualizado y el menú del 30 nov", lead: "Este es el presupuesto actualizado para tus 4 semanas:" },
    en: { subject: "Radici: your updated quote and menu for 30 Nov", lead: "Here is the updated quote for your 4 weeks:" },
  };
  for (const locale of LOCALES) {
    const message = renderMenuMessage(input({ snapshot: quoteSnapshot(locale, quote({ version: 2 })) }));
    assert.equal(message.subject, expected[locale].subject, locale);
    assert.ok(message.text.includes(expected[locale].lead), `${locale}: ${message.text}`);
  }
});

test("español e inglés con el presupuesto: sus textos y el € con los separadores de cada idioma", () => {
  const es = renderMenuMessage(input({ snapshot: quoteSnapshot("es") }));
  assert.equal(es.subject, "Radici: tu presupuesto y el menú del 30 nov");
  for (const expected of [
    "Evelyn ha preparado el presupuesto para tus 4 semanas y el menú de la primera.",
    "EL PRESUPUESTO\nEste es el presupuesto para tus 4 semanas:\nSemana 1: lunes, 30 de noviembre de 2026, llegada a las 10:00",
    "Precio del servicio: 560,00 € en total (140,00 € por semana)",
    "Acéptalo dentro de las próximas 48 horas. Hasta entonces, estas fechas quedan reservadas para ti.",
    "Desde tu enlace puedes aceptar el presupuesto y el menú de la primera semana, pedir cambios o rechazarlo.",
    `Ver y aceptar el presupuesto: ${LINK}`,
  ]) {
    assert.ok(es.text.includes(expected), `es: ${expected}\n${es.text}`);
  }

  const pricey = quote({ totalCents: 112000, weeks: quote().weeks.map((week) => ({ ...week, serviceCents: 28000 })) });
  const en = renderMenuMessage(input({ snapshot: quoteSnapshot("en", pricey) }));
  assert.equal(en.subject, "Radici: your quote and menu for 30 Nov");
  for (const expected of [
    "Evelyn has prepared the quote for your 4 weeks and the menu for the first one.",
    "THE QUOTE\nHere is the quote for your 4 weeks:\nWeek 1: Monday 30 November 2026, arriving at 10:00",
    "Service price: €1,120.00 in total (€280.00 per week)",
    "Please accept it within 48 hours. Until then, these dates are held for you.",
    "From your link you can accept the quote and the first week's menu, ask for changes or decline it.",
    `See and accept the quote: ${LINK}`,
  ]) {
    assert.ok(en.text.includes(expected), `en: ${expected}\n${en.text}`);
  }
});

test("con el presupuesto: la vista previa sin link y nunca la forma ni el momento de pago, la dirección ni las alergias", () => {
  for (const locale of LOCALES) {
    const preview = renderMenuMessage(input({ snapshot: quoteSnapshot(locale), link: null }));
    for (const text of [preview.text, preview.whatsapp, preview.html]) {
      assert.ok(text.includes(linkPlaceholder(locale)), locale);
      assert.ok(!text.includes("#t="), `${locale}: sin token`);
    }
    const message = renderMenuMessage(input({ snapshot: quoteSnapshot(locale) }));
    for (const text of [message.subject, message.text, message.whatsapp, message.html]) {
      assert.ok(!PAYMENT_WORDS.test(text), `${locale}: habla de pagos: ${PAYMENT_WORDS.exec(text)?.[0]}`);
    }
  }
  // Una foto con el presupuesto y datos que no son del contrato: el mensaje sale sin ellos.
  const read = readMenuSnapshot({
    ...quoteSnapshot(),
    quote: { ...quote(), payment: "bonifico anticipato", address: "Via Segretissima 42" },
    restrictions: "celiachia grave",
  });
  assert.ok(read?.quote);
  const message = renderMenuMessage(input({ snapshot: read }));
  for (const text of [message.text, message.whatsapp, message.html]) {
    for (const marker of ["bonifico", "Segretissima", "celiachia"]) assert.ok(!text.includes(marker), marker);
  }
});

test("sin el presupuesto, el mensaje de siempre (confirmar el menú), también con otro «ahora»", () => {
  const message = renderMenuMessage(input({ now: new Date("2030-01-01T00:00:00Z") }));
  assert.equal(message.subject, "Radici: il menù della settimana 1 di 3 (30 nov)");
  assert.ok(message.text.includes(`Vedi e conferma il menù: ${LINK}`));
  assert.ok(!/preventivo|€/.test(message.text + message.whatsapp + message.html));
});
