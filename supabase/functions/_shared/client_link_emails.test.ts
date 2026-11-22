// Tests de los avisos a Evelyn de lo que contesta la clienta en su link (docs/contracts/client-link.md §6).
// Correr con: npm test (raíz).
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  renderMenuAnswerNotification,
  renderQuoteAnswerNotification,
  type MenuAnswerNotice,
  type QuoteAnswerNotice,
} from "./client_link_emails.ts";
import { LOCALES } from "./public_request.ts";

const REQUEST_ID = "1b4e28ba-2fa1-41d2-883f-0016d3cca427";

function notice(overrides: Partial<MenuAnswerNotice> = {}): MenuAnswerNotice {
  return {
    kind: "confirmed",
    brand: "Radici",
    clientName: "Anna Bianchi",
    requestId: REQUEST_ID,
    week: 1,
    weeks: 4,
    date: "2027-03-01",
    start: "10:00",
    inboxUrl: "https://radicicucina.app/gestione/",
    ...overrides,
  };
}

test("confirmó el menú: asunto con el nombre de pila, la semana, la fecha larga y la hora, y el botón al pedido (es)", () => {
  const email = renderMenuAnswerNotification(notice(), "es");
  assert.equal(email.subject, "Anna confirmó el menú de la semana 1");
  assert.match(email.text, /^Menú confirmado\n\nAnna Bianchi confirmó el menú de la semana 1 de 4 \(lunes, 1 de marzo de 2027, llegada a las 10:00\)\./);
  assert.ok(email.text.includes(`Abrir en la bandeja: https://radicicucina.app/gestione/#/richieste/${REQUEST_ID}`));
  assert.ok(email.html.includes(`href="https://radicicucina.app/gestione/#/richieste/${REQUEST_ID}"`));
  assert.ok(email.html.startsWith('<!doctype html><html lang="es">'));
  assert.ok(email.text.includes("Aviso automático de Radici."));
});

test("pidió cambios: lo dice y manda a leer el mensaje en la app, sin el mensaje (es)", () => {
  const email = renderMenuAnswerNotification(notice({ kind: "changes", week: 2 }), "es");
  assert.equal(email.subject, "Anna pidió cambios en el menú de la semana 2");
  assert.ok(email.text.includes("Anna Bianchi pidió cambios en el menú de la semana 2 de 4 (lunes, 1 de marzo de 2027, llegada a las 10:00)."));
  assert.ok(email.text.includes("Su mensaje está en la app, en el pedido: cambia el menú y vuelve a enviárselo."));
});

test("en los tres idiomas (CHEF_LOCALE)", () => {
  const expected = {
    it: {
      confirmed: "Anna ha confermato il menù della settimana 1",
      changes: "Anna chiede dei cambi al menù della settimana 1",
      date: "lunedì 1 marzo 2027, arrivo alle 10:00",
      button: "Apri la richiesta",
    },
    es: {
      confirmed: "Anna confirmó el menú de la semana 1",
      changes: "Anna pidió cambios en el menú de la semana 1",
      date: "lunes, 1 de marzo de 2027, llegada a las 10:00",
      button: "Abrir en la bandeja",
    },
    en: {
      confirmed: "Anna confirmed the menu for week 1",
      changes: "Anna asked for changes to the menu for week 1",
      date: "Monday 1 March 2027, arriving at 10:00",
      button: "Open in the inbox",
    },
  } as const;
  for (const locale of LOCALES) {
    for (const kind of ["confirmed", "changes"] as const) {
      const email = renderMenuAnswerNotification(notice({ kind }), locale);
      assert.equal(email.subject, expected[locale][kind], `${locale} ${kind}`);
      assert.ok(email.text.includes(expected[locale].date), `${locale} ${kind}: ${email.text}`);
      assert.ok(email.text.includes(expected[locale].button), `${locale} ${kind}`);
    }
  }
});

test("asunto: solo un nombre de pila que parece un nombre; sin nombre, «la clienta» en el cuerpo", () => {
  for (const clientName of ["+39 333 1234567", "bit.ly/premio", "ana@example.test", "", null]) {
    const email = renderMenuAnswerNotification(notice({ clientName }), "es");
    assert.equal(email.subject, "Menú de la semana 1 confirmado", String(clientName));
  }
  const nameless = renderMenuAnswerNotification(notice({ clientName: "  " }), "es");
  assert.ok(nameless.text.includes("La clienta confirmó el menú de la semana 1 de 4"));
  const changes = renderMenuAnswerNotification(notice({ kind: "changes", clientName: null }), "it");
  assert.equal(changes.subject, "Cambi richiesti al menù della settimana 1");
  assert.ok(changes.text.includes("La cliente ha chiesto dei cambi"));
});

test("el nombre de la clienta va escapado en el HTML", () => {
  const email = renderMenuAnswerNotification(notice({ clientName: 'Anna <img src=x onerror="alert(1)">' }), "es");
  assert.ok(!email.html.includes("<img src=x"));
  assert.ok(email.html.includes("Anna &lt;img src=x onerror=&quot;alert(1)&quot;&gt;"));
});

test("sin INBOX_URL (o con una que no es http), sin botón", () => {
  for (const inboxUrl of [null, "javascript:alert(1)", "radicicucina.app/gestione"]) {
    const email = renderMenuAnswerNotification(notice({ inboxUrl }), "es");
    assert.ok(!email.html.includes("<a "), String(inboxUrl));
    assert.ok(!email.text.includes("Abrir en la bandeja"), String(inboxUrl));
  }
});

// ---------------------------------------------------------------------------
// El presupuesto: aceptado o rechazado
// ---------------------------------------------------------------------------

function quoteNotice(overrides: Partial<QuoteAnswerNotice> = {}): QuoteAnswerNotice {
  return {
    kind: "accepted",
    brand: "Radici",
    clientName: "Anna Bianchi",
    requestId: REQUEST_ID,
    date: "2027-03-01",
    start: "10:00",
    weeks: 4,
    totalCents: 56000,
    inboxUrl: "https://radicicucina.app/gestione/",
    ...overrides,
  };
}

test("aceptó el presupuesto: las semanas y el precio del servicio, la primera semana y el botón al pedido (es)", () => {
  const email = renderQuoteAnswerNotification(quoteNotice(), "es");
  assert.equal(email.subject, "Anna aceptó el presupuesto");
  assert.match(email.text, /^Presupuesto aceptado\n\nAnna Bianchi aceptó el presupuesto: 4 semanas, 560,00 €\./);
  assert.ok(email.text.includes("La primera semana es el lunes, 1 de marzo de 2027, con llegada a las 10:00."));
  assert.ok(email.text.includes("Las semanas quedaron confirmadas en la agenda, y el menú de la semana 1 también."));
  assert.ok(email.text.includes(`Abrir en la bandeja: https://radicicucina.app/gestione/#/richieste/${REQUEST_ID}`));
  assert.ok(email.html.startsWith('<!doctype html><html lang="es">'));
});

test("rechazó el presupuesto: lo dice, con el día en que empezaba y que lo propuesto quedó libre, sin contar semanas (es)", () => {
  const email = renderQuoteAnswerNotification(quoteNotice({ kind: "declined", weeks: null, totalCents: null }), "es");
  assert.equal(email.subject, "Anna rechazó el presupuesto");
  assert.ok(email.text.includes("Anna Bianchi rechazó el presupuesto."));
  assert.ok(email.text.includes("El presupuesto empezaba el lunes, 1 de marzo de 2027, con llegada a las 10:00."));
  assert.ok(email.text.includes("Lo que le propusiste quedó libre en la agenda."));
  assert.ok(email.html.includes("Lo que le propusiste quedó libre."), "el preheader");
  assert.ok(!email.text.includes("€"));
  // Al rechazar no se sabe cuántas semanas eran (pueden ser una): nada de «la primera semana» ni «las semanas».
  assert.ok(!/semanas?\b/i.test(email.text + email.html), email.text);
});

test("aceptó un presupuesto de una sola semana: el día y que quedaron confirmados la fecha y el menú, en singular (CHEF_LOCALE)", () => {
  const expected = {
    it: {
      preheader: "La data è confermata in agenda.",
      first: "Il giorno è lunedì 1 marzo 2027, con arrivo alle 10:00.",
      note: "La data è confermata in agenda, e anche il menù.",
      plural: /prima settimana|le settimane|settimana 1/i,
    },
    es: {
      preheader: "La fecha quedó confirmada en la agenda.",
      first: "El día es el lunes, 1 de marzo de 2027, con llegada a las 10:00.",
      note: "La fecha quedó confirmada en la agenda, y el menú también.",
      plural: /primera semana|las semanas|semana 1/i,
    },
    en: {
      preheader: "The date is confirmed in the calendar.",
      first: "The day is Monday 1 March 2027, arriving at 10:00.",
      note: "The date is confirmed in the calendar, and so is the menu.",
      plural: /first week|the weeks|week 1\b/i,
    },
  } as const;
  for (const locale of LOCALES) {
    const email = renderQuoteAnswerNotification(quoteNotice({ weeks: 1, totalCents: 15000 }), locale);
    assert.ok(email.text.includes(expected[locale].first), `${locale}: ${email.text}`);
    assert.ok(email.text.includes(expected[locale].note), `${locale}: ${email.text}`);
    assert.ok(email.html.includes(expected[locale].preheader), `${locale}: el preheader`);
    assert.ok(!expected[locale].plural.test(email.text + email.html), `${locale}: ${expected[locale].plural.exec(email.text + email.html)?.[0]}`);
  }
  // Con varias semanas, el plural de siempre.
  const several = renderQuoteAnswerNotification(quoteNotice(), "it");
  assert.ok(several.text.includes("La prima settimana è lunedì 1 marzo 2027, con arrivo alle 10:00."));
  assert.ok(several.text.includes("Le settimane sono confermate in agenda, e anche il menù della settimana 1."));
  assert.ok(several.html.includes("Le settimane sono confermate in agenda."));
});

test("rechazó, en los tres idiomas: sin contar semanas (la base no lo dice)", () => {
  const expected = {
    it: ["Il preventivo cominciava lunedì 1 marzo 2027, con arrivo alle 10:00.", "Quello che le avevi proposto è di nuovo libero in agenda."],
    es: ["El presupuesto empezaba el lunes, 1 de marzo de 2027, con llegada a las 10:00.", "Lo que le propusiste quedó libre en la agenda."],
    en: ["The quote started on Monday 1 March 2027, arriving at 10:00.", "What you proposed is free again in the calendar."],
  } as const;
  for (const locale of LOCALES) {
    const email = renderQuoteAnswerNotification(quoteNotice({ kind: "declined", weeks: null, totalCents: null }), locale);
    for (const line of expected[locale]) assert.ok(email.text.includes(line), `${locale}: ${line}\n${email.text}`);
    assert.ok(!/settiman|semana|week/i.test(email.text), `${locale}: ${email.text}`);
  }
});

test("presupuesto en los tres idiomas (CHEF_LOCALE), una semana en singular, y nunca nada de pagos", () => {
  const expected = {
    it: { accepted: "Anna ha accettato il preventivo", declined: "Anna ha rifiutato il preventivo", body: "Anna Bianchi ha accettato il preventivo: 1 settimana, 150,00 €." },
    es: { accepted: "Anna aceptó el presupuesto", declined: "Anna rechazó el presupuesto", body: "Anna Bianchi aceptó el presupuesto: 1 semana, 150,00 €." },
    en: { accepted: "Anna accepted the quote", declined: "Anna declined the quote", body: "Anna Bianchi accepted the quote: 1 week, €150.00." },
  } as const;
  for (const locale of LOCALES) {
    const accepted = renderQuoteAnswerNotification(quoteNotice({ weeks: 1, totalCents: 15000 }), locale);
    assert.equal(accepted.subject, expected[locale].accepted, locale);
    assert.ok(accepted.text.includes(expected[locale].body), `${locale}: ${accepted.text}`);
    const declined = renderQuoteAnswerNotification(quoteNotice({ kind: "declined", weeks: null, totalCents: null }), locale);
    assert.equal(declined.subject, expected[locale].declined, locale);
    for (const text of [accepted.text, accepted.html, declined.text, declined.html]) {
      assert.ok(!/pagament|pagar|\bpago|payment|bonifico|transfer|contanti|efectivo|\bcash\b|tarjeta|\bcard\b/i.test(text), `${locale}: ${text}`);
    }
  }
});

test("presupuesto: sin nombre, «la clienta»; el nombre va escapado; sin INBOX_URL, sin botón", () => {
  const nameless = renderQuoteAnswerNotification(quoteNotice({ clientName: "+39 333 1234567" }), "es");
  assert.equal(nameless.subject, "Presupuesto aceptado");
  const blank = renderQuoteAnswerNotification(quoteNotice({ clientName: null, kind: "declined", weeks: null, totalCents: null }), "it");
  assert.equal(blank.subject, "Preventivo rifiutato");
  assert.ok(blank.text.includes("La cliente ha rifiutato il preventivo."));
  const evil = renderQuoteAnswerNotification(quoteNotice({ clientName: 'Anna <img src=x onerror="alert(1)">' }), "es");
  assert.ok(!evil.html.includes("<img src=x"));
  const noInbox = renderQuoteAnswerNotification(quoteNotice({ inboxUrl: null }), "es");
  assert.ok(!noInbox.html.includes("<a "));
});
