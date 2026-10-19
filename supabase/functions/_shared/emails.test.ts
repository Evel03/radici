// Tests de los emails del pedido (contrato §5). Correr con: npm test.
import { test } from "node:test";
import assert from "node:assert/strict";
import { LOCALES } from "./public_request.ts";
import {
  brandFromMailFrom,
  escapeHtml,
  firstName,
  formatCents,
  formatDateLong,
  formatPeople,
  inboxRequestUrl,
  privacyPageUrl,
  renderChefNotification,
  renderClientConfirmation,
  safeHttpUrl,
  subjectFirstName,
  type ChefNotificationInput,
  type ClientConfirmationInput,
  type RequestSummary,
} from "./emails.ts";

const REQUEST_ID = "1b4e28ba-2fa1-41d2-883f-0016d3cca427";

const SUMMARY: RequestSummary = {
  requestId: REQUEST_ID,
  type: "week",
  adults: 2,
  kids: 2,
  days: 5,
  meals: ["dinner"],
  preferredDate: "2026-10-25",
  slot: "afternoon",
  hasRestrictions: true,
  estimate: { portions: 20, cookMinutes: 180, serviceCents: 7800, groceriesEstCents: 6300, totalCents: 14100 },
};

function clientInput(overrides: Partial<ClientConfirmationInput> = {}): ClientConfirmationInput {
  return {
    brand: "Radici",
    chefName: "Evelyn",
    customerName: "Giulia Rossi",
    summary: SUMMARY,
    privacyUrl: "https://radici.sepusola10.com/privacy/",
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
    inboxUrl: "https://radici.sepusola10.com/gestione/",
    ...overrides,
  };
}

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

test("nombre de pila: la primera palabra, con tope de largo", () => {
  assert.equal(firstName("Giulia Rossi"), "Giulia");
  assert.equal(firstName("  Maria   Grazia Rossi "), "Maria");
  assert.equal(firstName(""), "");
  assert.equal(firstName("x".repeat(60)).length, 40);
});

test("nombre para el asunto: solo si parece un nombre (nunca un teléfono o un email)", () => {
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
    ["", ""],
  ] as const) {
    assert.equal(subjectFirstName(input), expected, input);
  }
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
  assert.equal(brandFromMailFrom("Radici <ciao@radici.sepusola10.com>"), "Radici");
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
    lines: ["Grazie, Giulia!", "Evelyn ti contatterà al più presto", "Settimana di pasti", "2 adulti e 2 bambini",
      "Cena", "domenica 25 ottobre 2026", "Pomeriggio", "Hai indicato restrizioni alimentari: Evelyn ne terrà conto.",
      "78,00 €", "63,00 €", "141,00 €", "La spesa si paga al costo reale dello scontrino"],
  },
  es: {
    subject: "Radici: hemos recibido tu solicitud",
    lines: ["¡Gracias, Giulia!", "Evelyn te contactará lo antes posible", "Semana de comidas", "2 adultos y 2 niños",
      "Cena", "domingo, 25 de octubre de 2026", "Tarde", "Indicaste restricciones alimentarias: Evelyn las tendrá en cuenta.",
      "78,00 €", "63,00 €", "141,00 €", "La compra se paga al precio real del ticket"],
  },
  en: {
    subject: "Radici: we've received your request",
    lines: ["Thank you, Giulia!", "Evelyn will contact you as soon as possible", "A week of meals", "2 adults and 2 children",
      "Dinner", "Sunday 25 October 2026", "Afternoon", "You mentioned dietary restrictions: Evelyn will take them into account.",
      "€78.00", "€63.00", "€141.00", "Groceries are charged at the actual receipt cost"],
  },
} as const;

for (const locale of LOCALES) {
  test(`cliente (${locale}): asunto sin datos personales; saludo, resumen, aviso genérico y estimación`, () => {
    const email = renderClientConfirmation(clientInput(), locale);
    const expected = EXPECTED_CLIENT[locale];
    assert.equal(email.subject, expected.subject);
    for (const line of expected.lines) {
      assert.ok(email.text.includes(line), `falta en el texto: ${line}`);
      assert.ok(email.html.includes(escapeHtml(line)), `falta en el HTML: ${line}`);
    }
    assert.ok(email.html.startsWith("<!doctype html>"));
    assert.ok(email.html.includes(`<html lang="${locale}">`));
    assert.ok(email.html.includes('href="https://radici.sepusola10.com/privacy/"'));
    assert.ok(email.text.includes("https://radici.sepusola10.com/privacy/"));
    assert.ok(email.text.includes(REQUEST_ID.slice(0, 8)), "referencia corta del pedido");
    assert.ok(!email.text.includes("Rossi") && !email.html.includes("Rossi"), "solo el nombre de pila");
  });
}

test("los textos del usuario se escapan y no hay imágenes remotas ni scripts", () => {
  const client = renderClientConfirmation(clientInput({ customerName: "<b>Giulia</b> Rossi", chefName: `Eve "<i>"` }), "it");
  assert.ok(client.html.includes("Grazie, &lt;b&gt;Giulia&lt;/b&gt;!"));
  assert.ok(client.html.includes("Eve &quot;&lt;i&gt;&quot;"));
  assert.ok(!/<b>Giulia|<i>/.test(client.html));

  const chef = renderChefNotification(chefInput({ customerName: "<img src=x onerror=alert(1)> Rossi", zone: "<script>z</script>" }), "it");
  assert.ok(chef.html.includes("&lt;img src=x onerror=alert(1)&gt; Rossi"));
  assert.ok(chef.html.includes("&lt;script&gt;z&lt;/script&gt;"));
  for (const email of [client, chef]) {
    assert.ok(!/<img\b|<script\b|\bonerror=/i.test(email.html.replace(/&lt;img src=x onerror=alert\(1\)&gt;/g, "")));
  }
});

test("cliente: sin restricciones no hay aviso; sin fecha, 'sin preferencia'; ambas comidas", () => {
  const email = renderClientConfirmation(
    clientInput({ summary: { ...SUMMARY, hasRestrictions: false, preferredDate: null, meals: ["lunch", "dinner"], type: "extra" } }),
    "it",
  );
  assert.ok(!email.text.includes("restrizioni"));
  assert.ok(email.text.includes("Nessuna preferenza"));
  assert.ok(email.text.includes("Pranzo e cena"));
  assert.ok(email.text.includes("Evento o sessione extra"));
});

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
    "Ha indicato restrizioni alimentari: le trovi nell'app.", "Ha lasciato delle note: le trovi nell'app.", "141,00 €"]) {
    assert.ok(email.text.includes(line), `falta en el texto: ${line}`);
    assert.ok(email.html.includes(escapeHtml(line)), `falta en el HTML: ${line}`);
  }
  const inbox = `https://radici.sepusola10.com/gestione/#/richieste/${REQUEST_ID}`;
  assert.ok(email.html.includes(`href="${inbox}"`));
  assert.ok(email.text.includes(inbox));
  assert.ok(email.html.includes('href="tel:+393331234567"'));
  assert.ok(email.html.includes('href="mailto:giulia@example.test"'));
});

test("Evelyn en español e inglés, sin notas ni WhatsApp", () => {
  const es = renderChefNotification(chefInput({ hasNotes: false, whatsappOptIn: false, summary: { ...SUMMARY, hasRestrictions: false } }), "es");
  assert.equal(es.subject, "Nueva solicitud de Giulia");
  assert.ok(es.text.includes("Abrir en la bandeja"));
  assert.ok(es.text.includes("No indicó restricciones alimentarias."));
  assert.ok(!es.text.includes("notas"));
  assert.ok(es.text.includes("Confirmación por WhatsApp: No"));

  const en = renderChefNotification(chefInput(), "en");
  assert.equal(en.subject, "New request from Giulia");
  assert.ok(en.text.includes("Open in the inbox"));
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
  assert.ok(email.html.includes('href="mailto:a&quot;&gt;&lt;script&gt;x@example.test"'));
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
