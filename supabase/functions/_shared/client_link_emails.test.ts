// Tests de los avisos a Evelyn de lo que contesta la clienta en su link (docs/contracts/client-link.md §6).
// Correr con: npm test (raíz).
import { test } from "node:test";
import assert from "node:assert/strict";
import { renderMenuAnswerNotification, type MenuAnswerNotice } from "./client_link_emails.ts";
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

test("el nombre de la ficha va escapado en el HTML", () => {
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
