// Tests de los emails del pedido (contrato §5). Correr con: npm test.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { LOCALES, type Locale } from "./public_request.ts";
import {
  allergyAnswer,
  brandFromMailFrom,
  emailWithBreaks,
  escapeHtml,
  firstName,
  formatCents,
  formatDateLong,
  formatPeople,
  inboxRequestUrl,
  privacyPageUrl,
  renderChefNotification,
  renderClientConfirmation,
  safeFirstName,
  safeHttpUrl,
  type AllergyAnswer,
  type ChefNotificationInput,
  type ClientConfirmationInput,
  type RequestSummary,
} from "./emails.ts";

const REQUEST_ID = "1b4e28ba-2fa1-41d2-883f-0016d3cca427";

/** 4 semanas desde el domingo 25/10/2026, con la tarifa con descuento (vector 3). */
const SUMMARY: RequestSummary = {
  requestId: REQUEST_ID,
  type: "week",
  adults: 2,
  kids: 2,
  days: 5,
  meals: ["dinner"],
  weeks: 4,
  preferredDate: "2026-10-25",
  slot: "afternoon",
  allergies: "listed",
  estimate: {
    autoPrice: true,
    weeklyServiceCents: 14000,
    serviceCents: 56000,
    savingsCents: 4000,
    regularWeeklyCents: 15000,
    groceriesEstCents: 6300,
  },
};

/** Una semana, sin descuento (vector 1). */
const ONE_WEEK: RequestSummary = {
  ...SUMMARY,
  weeks: 1,
  estimate: { autoPrice: true, weeklyServiceCents: 15000, serviceCents: 15000, savingsCents: 0, regularWeeklyCents: 15000, groceriesEstCents: 6300 },
};

/** 6 personas: sin precio automático (vector 7). */
const SIX_PEOPLE: RequestSummary = {
  ...SUMMARY,
  adults: 3,
  kids: 3,
  weeks: 2,
  estimate: { autoPrice: false, reason: "people", maxPeople: 5, groceriesEstCents: 9450 },
};

/** Sesión extra: sin precio automático ni semanas (vector 8). */
const EXTRA: RequestSummary = {
  ...SUMMARY,
  type: "extra",
  adults: 10,
  kids: 6,
  days: 1,
  weeks: 1,
  estimate: { autoPrice: false, reason: "extra", maxPeople: 5, groceriesEstCents: 5300 },
};

function clientInput(overrides: Partial<ClientConfirmationInput> = {}): ClientConfirmationInput {
  return {
    brand: "Radici",
    chefName: "Evelyn",
    customerName: "Giulia Rossi",
    summary: SUMMARY,
    privacyUrl: "https://radicicucina.app/privacy/",
    ...overrides,
  };
}

function chefInput(overrides: Partial<ChefNotificationInput> = {}): ChefNotificationInput {
  return {
    brand: "Radici",
    customerName: "Giulia Rossi",
    zone: "Città Alta",
    phoneE164: "+393331234567",
    email: "giulia@example.test",
    whatsappOptIn: true,
    hasNotes: true,
    summary: SUMMARY,
    inboxUrl: "https://radicicucina.app/gestione/",
    ...overrides,
  };
}

test("franja: la web ya no la pregunta ('any'), así que no aparece; un pedido con mañana o tarde la muestra", () => {
  const labels = { it: "Fascia oraria", es: "Franja horaria", en: "Time of day" } as const;
  for (const locale of LOCALES) {
    const any = { ...SUMMARY, slot: "any" as const };
    for (const email of [renderClientConfirmation(clientInput({ summary: any }), locale), renderChefNotification(chefInput({ summary: any }), locale)]) {
      assert.ok(!email.text.includes(labels[locale]), `${locale}: sin franja con 'any'`);
    }
    assert.ok(renderChefNotification(chefInput(), locale).text.includes(labels[locale]), `${locale}: con 'afternoon' se muestra`);
  }
});

test("importes con enteros: it y es con coma y € al final; en con € adelante", () => {
  assert.equal(formatCents(14100, "it"), "141,00 €");
  assert.equal(formatCents(123456, "it"), "1.234,56 €");
  assert.equal(formatCents(5, "es"), "0,05 €");
  assert.equal(formatCents(0, "es"), "0,00 €");
  assert.equal(formatCents(14100, "en"), "€141.00");
  assert.equal(formatCents(123456, "en"), "€1,234.56");
  assert.throws(() => formatCents(1.5, "it"), RangeError);
  assert.throws(() => formatCents(-1, "it"), RangeError);
});

test("fecha larga en cada idioma, sin depender de la zona horaria", () => {
  assert.equal(formatDateLong("2026-10-25", "it"), "domenica 25 ottobre 2026");
  assert.equal(formatDateLong("2026-10-25", "es"), "domingo, 25 de octubre de 2026");
  assert.equal(formatDateLong("2026-10-25", "en"), "Sunday 25 October 2026");
  assert.equal(formatDateLong("2027-01-01", "it"), "venerdì 1 gennaio 2027");
  assert.equal(formatDateLong("no-es-fecha", "it"), "no-es-fecha");
});

test("personas en cada idioma", () => {
  assert.equal(formatPeople(2, 2, "it"), "2 adulti e 2 bambini");
  assert.equal(formatPeople(1, 0, "it"), "1 adulto");
  assert.equal(formatPeople(0, 3, "it"), "3 bambini");
  assert.equal(formatPeople(1, 1, "it"), "1 adulto e 1 bambino");
  assert.equal(formatPeople(2, 1, "es"), "2 adultos y 1 niño");
  assert.equal(formatPeople(1, 2, "en"), "1 adult and 2 children");
});

test("escapeHtml escapa los cinco caracteres especiales", () => {
  assert.equal(escapeHtml(`<b>"Tom" & 'Jerry'</b>`), "&lt;b&gt;&quot;Tom&quot; &amp; &#39;Jerry&#39;&lt;/b&gt;");
});

test("emailWithBreaks: escapa primero y después agrega los cortes (después de la @, antes de cada punto)", () => {
  assert.equal(emailWithBreaks("giulia.rossi@gmail.com"), "giulia<wbr>.rossi@<wbr>gmail<wbr>.com");
  assert.equal(emailWithBreaks(`a"<b>'&@x.it`), "a&quot;&lt;b&gt;&#39;&amp;@<wbr>x<wbr>.it");
  assert.equal(emailWithBreaks("sin-arroba"), "sin-arroba");
});

test("nombre de pila: la primera palabra, con tope de largo", () => {
  assert.equal(firstName("Giulia Rossi"), "Giulia");
  assert.equal(firstName("  Maria   Grazia Rossi "), "Maria");
  assert.equal(firstName(""), "");
  assert.equal(firstName("x".repeat(60)).length, 40);
});

test("nombre de pila seguro: solo si parece un nombre (nunca un teléfono, un email ni un link)", () => {
  for (const [input, expected] of [
    ["Giulia Rossi", "Giulia"],
    ["José Pérez", "José"],
    ["D'Angelo", "D'Angelo"],
    ["Jean-Luc Picard", "Jean-Luc"],
    ["Zoë", "Zoë"],
    ["Ἀθηνᾶ", "Ἀθηνᾶ"],
    ["+39 333 123 4567", ""],
    ["3331234567 Rossi", ""],
    ["giulia@example.test", ""],
    ["Giulia2", ""],
    ["-Giulia", ""],
    ["<b>Giulia</b>", ""],
    // Ni links ni dominios: el saludo y el WhatsApp llegan a direcciones que nadie verificó.
    ["https://bit.ly/3xYzAbC Rossi", ""],
    ["paypal-verify.com", ""],
    ["bit.ly/abc", ""],
    ["J.R.", ""],
    ["x".repeat(30), "x".repeat(30)],
    ["x".repeat(31), ""],
    ["", ""],
  ] as const) {
    assert.equal(safeFirstName(input), expected, input);
  }
});

test("cliente: si el nombre no parece un nombre, el saludo es el genérico (sin el texto del formulario)", () => {
  for (const customerName of ["https://bit.ly/3xYzAbC Rossi", "paypal-verify.com", "+39 333 123 4567"]) {
    const email = renderClientConfirmation(clientInput({ customerName }), "it");
    assert.ok(email.text.startsWith("Grazie!\n"), email.text.slice(0, 40));
    assert.ok(email.html.includes(">Grazie!</h1>"));
    for (const leak of ["bit.ly", "paypal", "333"]) {
      assert.ok(!email.text.includes(leak) && !email.html.includes(leak), `${customerName}: se coló ${leak}`);
    }
  }
  assert.ok(renderClientConfirmation(clientInput({ customerName: "paypal-verify.com" }), "es").text.startsWith("¡Gracias!\n"));
  assert.ok(renderClientConfirmation(clientInput({ customerName: "paypal-verify.com" }), "en").text.startsWith("Thank you!\n"));
});

test("Evelyn: si el nombre es un teléfono o un email, el asunto es el genérico", () => {
  for (const customerName of ["+39 333 123 4567", "giulia@example.test"]) {
    assert.equal(renderChefNotification(chefInput({ customerName }), "es").subject, "Nueva solicitud desde la web");
    assert.equal(renderChefNotification(chefInput({ customerName }), "it").subject, "Nuova richiesta dal sito");
    assert.equal(renderChefNotification(chefInput({ customerName }), "en").subject, "New request from the website");
  }
});

test("ningún asunto lleva teléfono, email, zona ni datos de salud", () => {
  const leaky = { ...SUMMARY, allergens: ["milk"], restrictionsNote: "NOTA-DE-SALUD", address: "Via Gombito 12" } as unknown as RequestSummary;
  for (const locale of LOCALES) {
    const subjects = [
      renderClientConfirmation(clientInput({ summary: leaky }), locale).subject,
      renderChefNotification(chefInput({ summary: leaky }), locale).subject,
      renderChefNotification(chefInput({ summary: leaky, customerName: "+393331234567" }), locale).subject,
    ];
    for (const subject of subjects) {
      for (const secret of ["3331234567", "giulia@example.test", "Città Alta", "NOTA-DE-SALUD", "milk", "Gombito", "Rossi"]) {
        assert.ok(!subject.includes(secret), `${locale}: "${subject}" lleva ${secret}`);
      }
    }
  }
});

test("marca a partir de MAIL_FROM", () => {
  assert.equal(brandFromMailFrom("Radici <ciao@radicicucina.app>"), "Radici");
  assert.equal(brandFromMailFrom('"Cucina di Eve" <ciao@example.test>'), "Cucina di Eve");
  assert.equal(brandFromMailFrom("ciao@example.test"), "Radici");
  assert.equal(brandFromMailFrom(null), "Radici");
});

test("URLs: bandeja con el id del pedido, privacy en el idioma, solo http(s)", () => {
  assert.equal(inboxRequestUrl("https://x.example/gestione/", REQUEST_ID), `https://x.example/gestione/#/richieste/${REQUEST_ID}`);
  assert.equal(inboxRequestUrl("https://x.example/gestione/#/vieja", "abc"), "https://x.example/gestione/#/richieste/abc");
  assert.equal(privacyPageUrl("https://x.example", "it"), "https://x.example/privacy/");
  assert.equal(privacyPageUrl("https://x.example/", "es"), "https://x.example/privacy/?lang=es");
  assert.equal(safeHttpUrl("https://x.example/a?b=1"), "https://x.example/a?b=1");
  assert.equal(safeHttpUrl("http://localhost:5173/"), "http://localhost:5173/");
  assert.equal(safeHttpUrl("javascript:alert(1)"), null);
  assert.equal(safeHttpUrl("no es url"), null);
  assert.equal(safeHttpUrl(null), null);
});

const EXPECTED_CLIENT = {
  it: {
    subject: "Radici: abbiamo ricevuto la tua richiesta",
    lines: ["Grazie, Giulia!", "Evelyn ti contatterà al più presto", "prezzo finale", "Settimana di pasti", "Settimane: 4",
      "2 adulti e 2 bambini", "Giorni a settimana: 5", "Cena", "domenica 25 ottobre 2026", "Pomeriggio",
      "Settimane successive: 1 novembre, 8 novembre, 15 novembre", "Servizio a settimana: 140,00 €",
      "Servizio, 4 settimane: 560,00 €", "Risparmio: 40,00 € rispetto a 150,00 € a settimana",
      "Spesa stimata a settimana: 63,00 €", "La spesa si paga a parte, al costo reale dello scontrino"],
  },
  es: {
    subject: "Radici: hemos recibido tu solicitud",
    lines: ["¡Gracias, Giulia!", "Evelyn te contactará lo antes posible", "precio final", "Semana de comidas", "Semanas: 4",
      "2 adultos y 2 niños", "Días por semana: 5", "Cena", "domingo, 25 de octubre de 2026", "Tarde",
      "Semanas siguientes: 1 de noviembre, 8 de noviembre, 15 de noviembre", "Servicio por semana: 140,00 €",
      "Servicio, 4 semanas: 560,00 €", "Ahorro: 40,00 € frente a 150,00 € por semana",
      "Compra estimada por semana: 63,00 €", "La compra se paga aparte, al precio real del ticket"],
  },
  en: {
    subject: "Radici: we've received your request",
    lines: ["Thank you, Giulia!", "Evelyn will contact you as soon as possible", "final price", "A week of meals", "Weeks: 4",
      "2 adults and 2 children", "Days per week: 5", "Dinner", "Sunday 25 October 2026", "Afternoon",
      "Following weeks: 1 November, 8 November, 15 November", "Service per week: €140.00",
      "Service, 4 weeks: €560.00", "Saving: €40.00 compared with €150.00 a week",
      "Estimated groceries per week: €63.00", "Groceries are paid separately, at the actual receipt cost"],
  },
} as const;

for (const locale of LOCALES) {
  test(`cliente (${locale}): asunto sin datos personales; saludo, resumen, aviso genérico y estimación`, () => {
    const email = renderClientConfirmation(clientInput(), locale);
    const expected = EXPECTED_CLIENT[locale];
    assert.equal(email.subject, expected.subject);
    for (const line of expected.lines) {
      assert.ok(email.text.includes(line), `falta en el texto: ${line}`);
      // En el HTML la etiqueta y el valor de una fila van en dos celdas.
      for (const part of line.split(": ")) assert.ok(email.html.includes(escapeHtml(part)), `falta en el HTML: ${part}`);
    }
    assert.ok(email.html.startsWith("<!doctype html>"));
    assert.ok(email.html.includes(`<html lang="${locale}">`));
    assert.ok(email.html.includes('href="https://radicicucina.app/privacy/"'));
    assert.ok(email.text.includes("https://radicicucina.app/privacy/"));
    assert.ok(email.text.includes(REQUEST_ID.slice(0, 8)), "referencia corta del pedido");
    assert.ok(!email.text.includes("Rossi") && !email.html.includes("Rossi"), "solo el nombre de pila");
  });
}

test("los textos del usuario se escapan y no hay imágenes remotas ni scripts", () => {
  const client = renderClientConfirmation(clientInput({ customerName: "<b>Giulia</b> Rossi", chefName: `Eve "<i>"` }), "it");
  // "<b>Giulia</b>" no parece un nombre: saludo genérico, y nada del HTML del formulario.
  assert.ok(client.html.includes(">Grazie!</h1>"));
  assert.ok(!client.html.includes("Giulia&lt;"));
  assert.ok(client.html.includes("Eve &quot;&lt;i&gt;&quot;"));
  assert.ok(!/<b>Giulia|<i>/.test(client.html));

  const chef = renderChefNotification(chefInput({ customerName: "<img src=x onerror=alert(1)> Rossi", zone: "<script>z</script>" }), "it");
  assert.ok(chef.html.includes("&lt;img src=x onerror=alert(1)&gt; Rossi"));
  assert.ok(chef.html.includes("&lt;script&gt;z&lt;/script&gt;"));
  for (const email of [client, chef]) {
    assert.ok(!/<img\b|<script\b|\bonerror=/i.test(email.html.replace(/&lt;img src=x onerror=alert\(1\)&gt;/g, "")));
  }
});

test("cliente: sin fecha, 'sin preferencia'; ambas comidas; un evento", () => {
  const email = renderClientConfirmation(
    clientInput({ summary: { ...EXTRA, preferredDate: null, meals: ["lunch", "dinner"] } }),
    "it",
  );
  assert.ok(email.text.includes("Nessuna preferenza"));
  assert.ok(email.text.includes("Pranzo e cena"));
  assert.ok(email.text.includes("Evento o sessione extra"));
  // Una sesión extra no tiene semanas: sus días no son «a settimana».
  assert.ok(email.text.includes("Giorni: 1\n"));
  assert.ok(!email.text.includes("Settimane"));
});

test("una semana: una sola fila de servicio, sin ahorro ni semanas siguientes", () => {
  for (const email of [renderClientConfirmation(clientInput({ summary: ONE_WEEK }), "it"), renderChefNotification(chefInput({ summary: ONE_WEEK }), "it")]) {
    assert.ok(email.text.includes("Settimane: 1\n"));
    assert.ok(email.text.includes("Servizio: 150,00 €\n"));
    assert.ok(email.html.includes("<strong>150,00 €</strong>"), "el servicio destacado");
    assert.ok(email.text.includes("Spesa stimata a settimana: 63,00 €"));
    for (const absent of ["Servizio a settimana", "Risparmio", "Settimane successive"]) assert.ok(!email.text.includes(absent), absent);
  }
});

test("varias semanas: el total del servicio destacado y las fechas de las semanas siguientes, también cruzando el año", () => {
  const email = renderClientConfirmation(clientInput(), "it");
  assert.ok(email.html.includes("<strong>560,00 €</strong>"));
  // Sin fecha preferida no hay fechas que repetir.
  const noDate = renderClientConfirmation(clientInput({ summary: { ...SUMMARY, preferredDate: null } }), "it");
  assert.ok(!noDate.text.includes("Settimane successive"));
  assert.ok(noDate.text.includes("Settimane: 4"));
  const newYear = { ...SUMMARY, weeks: 3, preferredDate: "2026-12-21" };
  assert.ok(renderClientConfirmation(clientInput({ summary: newYear }), "it").text.includes("Settimane successive: 28 dicembre, 4 gennaio 2027\n"));
  assert.ok(renderChefNotification(chefInput({ summary: newYear }), "es").text.includes("Semanas siguientes: 28 de diciembre, 4 de enero de 2027\n"));
  assert.ok(renderChefNotification(chefInput({ summary: newYear }), "en").text.includes("Following weeks: 28 December, 4 January 2027\n"));
});

const NO_PRICE = {
  people: {
    client: {
      it: "Per più di 5 persone il prezzo del servizio te lo prepara Evelyn.",
      es: "Para más de 5 personas, el precio del servicio te lo prepara Evelyn.",
      en: "For more than 5 people, Evelyn will prepare the price of the service for you.",
    },
    chef: {
      it: "Più di 5 persone: senza prezzo automatico, prepara tu il preventivo.",
      es: "Más de 5 personas: sin precio automático, prepara tú el presupuesto.",
      en: "More than 5 people: no automatic price, prepare the quote yourself.",
    },
  },
  extra: {
    client: {
      it: "Per eventi e sessioni extra il prezzo del servizio te lo prepara Evelyn.",
      es: "Para eventos y sesiones extra, el precio del servicio te lo prepara Evelyn.",
      en: "For events and extra sessions, Evelyn will prepare the price of the service for you.",
    },
    chef: {
      it: "Evento o sessione extra: senza prezzo automatico, prepara tu il preventivo.",
      es: "Evento o sesión extra: sin precio automático, prepara tú el presupuesto.",
      en: "Event or extra session: no automatic price, prepare the quote yourself.",
    },
  },
} as const;

for (const locale of LOCALES) {
  test(`sin precio automático (${locale}): ni servicio ni total; el cliente lee que se lo prepara Evelyn y ella, que lo prepare`, () => {
    for (const [summary, reason] of [[SIX_PEOPLE, "people"], [EXTRA, "extra"]] as const) {
      const client = renderClientConfirmation(clientInput({ summary }), locale);
      const chef = renderChefNotification(chefInput({ summary }), locale);
      assert.ok(client.text.includes(NO_PRICE[reason].client[locale]), `${reason}: cliente`);
      assert.ok(client.html.includes(escapeHtml(NO_PRICE[reason].client[locale])));
      assert.ok(chef.text.includes(NO_PRICE[reason].chef[locale]), `${reason}: Evelyn`);
      for (const email of [client, chef]) {
        assert.ok(!/<strong>/.test(email.html), `${reason}: ningún importe destacado`);
        assert.ok(email.text.includes(formatCents(summary.estimate.groceriesEstCents, locale)), `${reason}: la compra estimada`);
      }
    }
    // La compra de una sesión extra no es «por semana»; la de un pedido semanal sí.
    const perWeek = { it: "Spesa stimata a settimana", es: "Compra estimada por semana", en: "Estimated groceries per week" } as const;
    assert.ok(renderClientConfirmation(clientInput({ summary: SIX_PEOPLE }), locale).text.includes(perWeek[locale]));
    assert.ok(!renderClientConfirmation(clientInput({ summary: EXTRA }), locale).text.includes(perWeek[locale]));
  });
}

// Al cliente, de las alergias solo la confirmación de que nadie tiene (le sirve para ver un error). Su
// dirección no está verificada y "hay alergias" es un dato de salud: con un email mal escrito le llegaría
// a otra persona. Lo que contestó ya lo ve en la pantalla de gracias.
const CLIENT_ALLERGIES: Readonly<Record<Locale, Readonly<Record<AllergyAnswer, string | null>>>> = {
  it: {
    none: "Hai confermato che nessuno ha allergie, intolleranze alimentari o celiachia.",
    listed: null,
    unknown: null,
  },
  es: {
    none: "Confirmaste que nadie tiene alergias, intolerancias alimentarias ni celiaquía.",
    listed: null,
    unknown: null,
  },
  en: {
    none: "You confirmed that nobody has any food allergies, intolerances or coeliac disease.",
    listed: null,
    unknown: null,
  },
};

/** Cualquier mención de alergias, intolerancias o celiaquía, en los tres idiomas. */
const ALLERGY_WORDS = /allerg|alerg|intoller|intoler|celiach|celiaqu|coeliac/i;

for (const locale of LOCALES) {
  test(`cliente (${locale}): solo le repite que nadie tiene alergias; con alergias escritas o sin respuesta, ni una palabra`, () => {
    for (const [answer, line] of Object.entries(CLIENT_ALLERGIES[locale]) as Array<[AllergyAnswer, string | null]>) {
      const email = renderClientConfirmation(clientInput({ summary: { ...SUMMARY, allergies: answer } }), locale);
      if (line === null) {
        assert.doesNotMatch(email.text, ALLERGY_WORDS, `${answer}: texto`);
        assert.doesNotMatch(email.html, ALLERGY_WORDS, `${answer}: HTML`);
      } else {
        assert.ok(email.text.includes(line), `${answer}: texto "${line}"`);
        assert.ok(email.html.includes(escapeHtml(line)), `${answer}: HTML "${line}"`);
      }
    }
  });
}

test("cliente: sin URL de privacy (o con una no http) no hay link", () => {
  for (const privacyUrl of [null, "javascript:alert(1)"]) {
    const email = renderClientConfirmation(clientInput({ privacyUrl }), "it");
    assert.ok(!email.html.includes("Informativa privacy"));
    assert.ok(!email.html.includes("javascript:"));
  }
});

test("Evelyn (it): asunto con el nombre de pila, contacto con links, botón a la bandeja", () => {
  const email = renderChefNotification(chefInput(), "it");
  assert.equal(email.subject, "Nuova richiesta da Giulia");
  for (const line of ["Giulia Rossi", "Città Alta", "+393331234567", "giulia@example.test", "Sì", "Settimana di pasti",
    "Ha indicato restrizioni alimentari: le trovi nell'app.", "Ha lasciato delle note: le trovi nell'app.", "560,00 €",
    "140,00 €", "1 novembre, 8 novembre, 15 novembre"]) {
    assert.ok(email.text.includes(line), `falta en el texto: ${line}`);
    assert.ok(email.html.includes(escapeHtml(line)), `falta en el HTML: ${line}`);
  }
  const inbox = `https://radicicucina.app/gestione/#/richieste/${REQUEST_ID}`;
  assert.ok(email.html.includes(`href="${inbox}"`));
  assert.ok(email.text.includes(inbox));
  assert.ok(email.html.includes('href="tel:+393331234567"'));
  assert.ok(email.html.includes('href="mailto:giulia@example.test"'));
});

test("Evelyn en español e inglés, sin notas ni WhatsApp", () => {
  const es = renderChefNotification(chefInput({ hasNotes: false, whatsappOptIn: false, summary: { ...SUMMARY, allergies: "none" } }), "es");
  assert.equal(es.subject, "Nueva solicitud de Giulia");
  assert.ok(es.text.includes("Abrir en la bandeja"));
  assert.ok(es.text.includes("Confirmó que nadie tiene alergias, intolerancias ni celiaquía."));
  assert.ok(!es.text.includes("notas"));
  assert.ok(es.text.includes("Confirmación por WhatsApp: No"));

  const en = renderChefNotification(chefInput(), "en");
  assert.equal(en.subject, "New request from Giulia");
  assert.ok(en.text.includes("Open in the inbox"));
});

const CHEF_ALLERGIES: Readonly<Record<Locale, Readonly<Record<AllergyAnswer, string>>>> = {
  it: {
    none: "Ha confermato che nessuno ha allergie, intolleranze o celiachia.",
    listed: "Ha indicato restrizioni alimentari: le trovi nell'app.",
    unknown: "Nessun dato sulle allergie: chiedi al cliente prima di preparare il menù.",
  },
  es: {
    none: "Confirmó que nadie tiene alergias, intolerancias ni celiaquía.",
    listed: "Indicó restricciones alimentarias: las ves en la app.",
    unknown: "Sin datos de alergias: pregúntale al cliente antes de preparar el menú.",
  },
  en: {
    none: "They confirmed that nobody has any allergies, intolerances or coeliac disease.",
    listed: "They mentioned dietary restrictions: see them in the app.",
    unknown: "No allergy information: ask the client before planning the menu.",
  },
};

for (const locale of LOCALES) {
  test(`Evelyn (${locale}): tres casos de alergias (nadie, indicadas en la app, sin datos), una sola línea`, () => {
    const all = Object.values(CHEF_ALLERGIES[locale]);
    for (const [answer, line] of Object.entries(CHEF_ALLERGIES[locale]) as Array<[AllergyAnswer, string]>) {
      const email = renderChefNotification(chefInput({ summary: { ...SUMMARY, allergies: answer } }), locale);
      for (const other of all) {
        const expected = other === line;
        assert.equal(email.text.includes(other), expected, `${answer}: texto "${other}"`);
        assert.equal(email.html.includes(escapeHtml(other)), expected, `${answer}: HTML "${other}"`);
      }
    }
  });
}

test("allergyAnswer: indicadas si hay restricciones; nadie solo si lo confirmó; si no, sin datos", () => {
  assert.equal(allergyAnswer(true, false), "none");
  assert.equal(allergyAnswer(false, true), "listed");
  // Con restricciones siempre se avisa que las vea, aunque diga lo contrario (más vale avisar de más).
  assert.equal(allergyAnswer(true, true), "listed");
  assert.equal(allergyAnswer(null, true), "listed");
  // Un pedido sin respuesta (anterior a la pregunta), o un "hay" sin restricciones: que pregunte.
  for (const noAllergies of [null, undefined, false]) assert.equal(allergyAnswer(noAllergies, false), "unknown");
});

test("Evelyn: sin INBOX_URL (o con una no http) no hay botón", () => {
  for (const inboxUrl of [null, "javascript:alert(1)"]) {
    const email = renderChefNotification(chefInput({ inboxUrl }), "it");
    assert.ok(!email.html.includes("Apri la richiesta"));
    assert.ok(!email.html.includes("javascript:"));
  }
});

test("Evelyn: un email con caracteres raros no rompe el atributo href", () => {
  const email = renderChefNotification(chefInput({ email: `a"><script>x@example.test` }), "it");
  assert.ok(!email.html.includes("<script>"));
  assert.ok(email.html.includes('href="mailto:a%22%3E%3Cscript%3Ex@example.test"'));
  // El texto visible es la dirección tal cual, escapada (con puntos de corte, que no se ven).
  assert.ok(email.html.includes("a&quot;&gt;&lt;script&gt;x@<wbr>example<wbr>.test</a>"));
});

test("Evelyn: el link mailto codifica la dirección (no se le pueden colar bcc, cc ni body)", () => {
  for (const address of ["?bcc=spy%40evil.example&body=hola@evil.example", "victim%40example.com?bcc=spy@evil.example", "a@b.com?cc=x"]) {
    const email = renderChefNotification(chefInput({ email: address }), "it");
    const href = /href="(mailto:[^"]*)"/.exec(email.html)?.[1] ?? "";
    assert.ok(href.startsWith("mailto:"), address);
    // Lo que queda después de "mailto:" no tiene separadores de campos sin codificar.
    assert.ok(!/[?&#]/.test(href.slice("mailto:".length).replaceAll("&amp;", "&")), `${address} → ${href}`);
    const url = new URL(href.replaceAll("&amp;", "&"));
    assert.equal(url.search, "", `${address}: sin parámetros`);
    assert.equal(decodeURIComponent(url.pathname), address, "el destinatario es la dirección completa");
  }
  assert.ok(renderChefNotification(chefInput(), "it").html.includes('href="mailto:giulia@example.test"'));
  assert.ok(renderChefNotification(chefInput({ email: "giulia+tag@example.test" }), "it").html.includes('href="mailto:giulia%2Btag@example.test"'));
});

test("ningún email copia datos de salud ni la dirección aunque el llamador los pase de más", () => {
  const leaky = {
    ...SUMMARY,
    allergens: ["milk"],
    diets: ["vegan"],
    restrictionsNote: "NOTA-DE-SALUD",
    notes: "NOTA-LIBRE",
    address: "Via Gombito 12",
  } as unknown as RequestSummary;
  const emails = [
    renderClientConfirmation(clientInput({ summary: leaky }), "en"),
    renderChefNotification(chefInput({ summary: leaky }), "en"),
  ];
  for (const email of emails) {
    for (const secret of ["NOTA-DE-SALUD", "NOTA-LIBRE", "Gombito", "vegan", "milk"]) {
      assert.ok(!email.html.includes(secret) && !email.text.includes(secret), `se filtró ${secret}`);
    }
  }
});

// ---------------------------------------------------------------------------
// Identidad de la marca (la misma de la web)
// ---------------------------------------------------------------------------

/** Textos de la web (web/src/i18n/*.json) que los emails repiten. */
function webCommon(locale: Locale): { slogan: string; brandTagline: string } {
  const json = JSON.parse(readFileSync(new URL(`../../../web/src/i18n/${locale}.json`, import.meta.url), "utf8")) as {
    common: { slogan: string; brandTagline: string };
  };
  return json.common;
}

/** El logotipo en texto: la tabla del nombre sobre el filete y el rótulo. */
const LOGO = /<table role="presentation" cellspacing="0" cellpadding="0" style="margin:0 auto;">[\s\S]*?<\/table>/;
const OLD_COLORS = ["#a3431c", "#fbf6ee", "#1c1713", "#6b5d52", "#e2d4c1"];

test("los dos emails llevan el logotipo en texto y la paleta del manual, sin la terracota de antes", () => {
  for (const email of [renderClientConfirmation(clientInput(), "it"), renderChefNotification(chefInput(), "es")]) {
    const logo = LOGO.exec(email.html)?.[0] ?? "";
    assert.match(logo, /font-variant:small-caps;[^"]*">Radici<\/td>/, "el nombre, en versalitas");
    assert.match(logo, /<td align="center" lang="it" [^>]*>Cucina privata<\/td>/, "el rótulo, en italiano");
    for (const color of ["#f5ede1", "#fbf7f1", "#dbc9b4", "#2c2b20", "#4a5a3c"]) assert.ok(email.html.includes(color), `falta ${color}`);
    for (const old of [...OLD_COLORS, "sans-serif"]) assert.ok(!email.html.includes(old), `queda ${old}`);
  }
  assert.ok(LOGO.exec(renderChefNotification(chefInput({ brand: "Cucina di Eve" }), "it").html)?.[0].includes(">Cucina di Eve</td>"));
});

test("logotipo: espaciado en px (Outlook resuelve los em contra 12 pt) y filete del color del texto (modo oscuro)", () => {
  const logo = LOGO.exec(renderClientConfirmation(clientInput(), "it").html)?.[0] ?? "";
  assert.doesNotMatch(logo, /letter-spacing:[\d.]+em/);
  // Outlook en modo oscuro aclara el texto pero no los bordes: el filete sigue al color del texto.
  assert.match(logo, /border-bottom:1px solid #2c2b20;border-bottom-color:currentColor;/);
});

test("Evelyn: un email largo se parte dentro de su columna y no ensancha la tarjeta en el teléfono", () => {
  const email = renderChefNotification(chefInput({ email: "mariagiovanna.bianchi@outlook.it" }), "es");
  assert.ok(email.html.includes(">mariagiovanna<wbr>.bianchi@<wbr>outlook<wbr>.it</a>"), "cortes después de la @ y antes de cada punto");
  assert.ok(email.text.includes("Email: mariagiovanna.bianchi@outlook.it\n"), "el texto plano, entero");
  // Las celdas de valor pueden partir una palabra que no entra (nombre, zona y email son texto libre).
  const valueCells = email.html.match(/<td style="padding:7px 0;[^"]*">/g) ?? [];
  assert.ok(valueCells.length >= 10);
  for (const cell of valueCells) assert.match(cell, /word-break:break-word;overflow-wrap:anywhere;/);
});

test("Outlook (Word) no hereda letra ni color en tablas anidadas: las tablas de filas los declaran", () => {
  for (const email of [renderClientConfirmation(clientInput(), "it"), renderChefNotification(chefInput(), "es")]) {
    const tables = email.html.match(/<table [^>]*border-collapse:collapse[^>]*>/g) ?? [];
    assert.ok(tables.length >= 2);
    for (const table of tables) assert.match(table, /font-family:'Palatino Linotype',[^;]*;color:#2c2b20;/);
  }
});

for (const locale of LOCALES) {
  test(`cliente (${locale}): el eslogan y el rótulo son los de la web; el aviso a Evelyn no lleva eslogan`, () => {
    const common = webCommon(locale);
    const email = renderClientConfirmation(clientInput(), locale);
    assert.ok(email.html.includes(`>${escapeHtml(common.slogan)}</p>`), "eslogan en el HTML");
    assert.ok(email.text.includes(`\n--\n${common.slogan}\n`), "eslogan en el texto, arriba del pie");
    assert.ok(email.html.includes(`>${escapeHtml(common.brandTagline)}</td>`), "rótulo del logotipo");
    const chef = renderChefNotification(chefInput(), locale);
    assert.ok(!chef.html.includes(common.slogan) && !chef.text.includes(common.slogan));
  });
}

test("la plantilla del código de acceso (Supabase Auth) tiene el mismo logotipo y colores", () => {
  const template = readFileSync(new URL("../../templates/login_code.html", import.meta.url), "utf8");
  const email = renderClientConfirmation(clientInput(), "it").html;
  assert.equal(LOGO.exec(template)?.[0].replaceAll("\n", ""), LOGO.exec(email)?.[0]);
  for (const color of ["#f5ede1", "#fbf7f1", "#dbc9b4", "#2c2b20", "#5b5847"]) assert.ok(template.includes(color), `falta ${color}`);
  for (const old of OLD_COLORS) assert.ok(!template.includes(old), `queda ${old}`);
  // El idioma del documento es el del texto, como en los emails (lectores de pantalla), y sale de
  // valores fijos: nunca el user_metadata.locale crudo, que escribe el usuario.
  assert.ok(
    template.includes(
      '<html lang="{{ if and .Data.locale (eq .Data.locale "es") }}es{{ else if and .Data.locale (eq .Data.locale "en") }}en{{ else }}it{{ end }}">',
    ),
  );
  assert.ok(!template.includes("{{ .Data.locale }}"));
});
