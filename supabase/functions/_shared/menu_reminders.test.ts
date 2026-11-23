// Tests del email de los avisos a Evelyn para completar el menú de cada semana (SPEC 5.8).
// Correr con: npm test (node --test).
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  dueRemindersFromRpc,
  reminderIdempotencyKey,
  renderMenuReminders,
  romeDateTime,
  type DueReminder,
} from "./menu_reminders.ts";

const ONE: DueReminder = {
  sessionId: "7e6b4000-0000-4000-8000-000000000001",
  requestId: "7e6b3000-0000-4000-8000-000000000001",
  kind: "first",
  date: "2027-01-11",
  start: "10:00",
  deadline: "2027-01-09T09:00:00+00:00",
  week: 2,
  weeks: 4,
  clientName: "Anna <Rota>",
  changesRequested: false,
};

const INPUT = { brand: "Radici", inboxUrl: "https://radicicucina.app/gestione/" };

test("dueRemindersFromRpc valida cada aviso", () => {
  assert.deepEqual(dueRemindersFromRpc([{ ...ONE, sessionId: ONE.sessionId.toUpperCase(), clientName: " Anna " }]), [
    { ...ONE, clientName: "Anna" },
  ]);
  assert.deepEqual(dueRemindersFromRpc([]), []);
  for (const bad of [
    null,
    {},
    [null],
    [{ ...ONE, kind: "nuevo" }],
    [{ ...ONE, sessionId: "no" }],
    [{ ...ONE, date: "2027-13-01" }],
    [{ ...ONE, start: "25:00" }],
    [{ ...ONE, deadline: "mañana" }],
    [{ ...ONE, week: 5 }],
    [{ ...ONE, weeks: 0 }],
    [{ ...ONE, clientName: 3 }],
    [{ ...ONE, changesRequested: "no" }],
  ]) {
    assert.equal(dueRemindersFromRpc(bad), null, JSON.stringify(bad));
  }
});

test("romeDateTime pasa a la hora de Roma, también con el horario de verano", () => {
  assert.deepEqual(romeDateTime("2027-01-09T09:00:00+00:00"), { date: "2027-01-09", time: "10:00" });
  assert.deepEqual(romeDateTime("2027-07-09T22:30:00Z"), { date: "2027-07-10", time: "00:30" });
});

test("un aviso: asunto con la clienta, cocina, límite y link al pedido", () => {
  const email = renderMenuReminders([ONE], INPUT, "es");
  assert.equal(email.subject, "Radici: Recordatorio: el menú de Anna <Rota>");
  assert.match(email.text, /ANNA <ROTA> · SEMANA 2 DE 4/);
  assert.match(email.text, /Cocina: lunes, 11 de enero de 2027, 10:00/);
  assert.match(email.text, /Enviarlo antes del: sábado, 9 de enero de 2027, 10:00/);
  assert.match(email.text, /La cocina es en menos de 4 días\./);
  assert.match(email.text, /Abrir el pedido: https:\/\/radicicucina\.app\/gestione\/#\/richieste\/7e6b3000-0000-4000-8000-000000000001/);
  assert.ok(email.html.includes("Anna &lt;Rota&gt;"));
  assert.ok(!email.html.includes("Anna <Rota>"));
});

test("urgente, con cambios pedidos, en los tres idiomas", () => {
  const overdue: DueReminder = { ...ONE, kind: "overdue", weeks: 1, week: 1, changesRequested: true, clientName: "Anna" };
  const es = renderMenuReminders([overdue], INPUT, "es");
  assert.equal(es.subject, "Radici: Urgente: manda el menú de Anna");
  assert.match(es.text, /La clienta pidió cambios: manda el menú corregido\./);
  assert.match(es.text, /Ya pasó el límite de 48 horas/);
  assert.ok(!/semana 1 de 1/i.test(es.text));

  const it = renderMenuReminders([overdue, { ...ONE, kind: "last" }], INPUT, "it");
  assert.equal(it.subject, "Radici: Urgente: 2 menù non ancora inviati");
  assert.match(it.text, /Cucina: lunedì 11 gennaio 2027, ore 10:00/);
  assert.match(it.text, /Il termine scade tra meno di 24 ore\./);

  const en = renderMenuReminders([{ ...ONE, kind: "last" }, { ...ONE, kind: "first" }], INPUT, "en");
  assert.equal(en.subject, "Radici: Reminder: 2 menus to send");
  assert.match(en.text, /Send by:/);
});

test("sin INBOX_URL no hay link", () => {
  const email = renderMenuReminders([ONE], { brand: "Radici", inboxUrl: null }, "es");
  assert.ok(!email.text.includes("Abrir el pedido"));
});

test("la clave de idempotencia cambia con el turno de 15 minutos y con los avisos", async () => {
  const a = await reminderIdempotencyKey("c", new Date("2027-01-09T09:01:00Z"), [ONE]);
  assert.equal(a, await reminderIdempotencyKey("c", new Date("2027-01-09T09:14:59Z"), [ONE]));
  assert.notEqual(a, await reminderIdempotencyKey("c", new Date("2027-01-09T09:15:00Z"), [ONE]));
  assert.notEqual(a, await reminderIdempotencyKey("c", new Date("2027-01-09T09:01:00Z"), [{ ...ONE, kind: "last" }]));
  assert.ok(a.length < 120);
});
