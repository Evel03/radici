// Tests de las partes puras del presupuesto (quotes.ts, contrato docs/contracts/chef-api.md §14): la lectura de lo
// que devuelven chef_create_quote, chef_update_quote (private.quote_terms) y chef_withdraw_quote, con la forma de la
// migración 20261121120000_quotes.sql. Correr con: npm test (node --test).
import { test } from "node:test";
import assert from "node:assert/strict";
import { createQuoteResponseFromRpc, quoteTermsFromRpc, withdrawQuoteResponseFromRpc } from "./quotes.ts";

const QUOTE_ID = "5e550000-0000-4000-8000-0000000000a1";
const REQUEST_ID = "5e550000-0000-4000-8000-000000000001";
const CLIENT_ID = "5e550000-0000-4000-8000-000000000002";
const SESSION_A = "5e550000-0000-4000-8000-0000000000b1";
const SESSION_B = "5e550000-0000-4000-8000-0000000000b2";

test("quoteTermsFromRpc: las semanas vivas con su precio y el total (la suma); otra forma, null", () => {
  const terms = {
    quoteId: QUOTE_ID,
    totalCents: 30001,
    weeks: [
      { sessionId: SESSION_A, date: "2026-11-23", start: "10:00", cookMinutes: 180, serviceCents: 15001 },
      { sessionId: SESSION_B, date: "2026-11-30", start: "10:00", cookMinutes: 180, serviceCents: 15000 },
    ],
  };
  assert.deepEqual(quoteTermsFromRpc(terms), terms);
  assert.deepEqual(quoteTermsFromRpc({ quoteId: QUOTE_ID, totalCents: 0, weeks: [] }), { quoteId: QUOTE_ID, totalCents: 0, weeks: [] }, "sin semanas vivas");
  const week = terms.weeks[0]!;
  const broken: Array<[string, unknown]> = [
    ["no es un objeto", null],
    ["presupuesto que no es un uuid", { ...terms, quoteId: "x" }],
    ["el total no es la suma", { ...terms, totalCents: 30000 }],
    ["centavos con decimales", { ...terms, totalCents: 15000.5, weeks: [{ ...week, serviceCents: 15000.5 }] }],
    ["hora con segundos", { ...terms, weeks: [{ ...week, start: "10:00:00" }], totalCents: 15001 }],
    ["fecha rota", { ...terms, weeks: [{ ...week, date: "23/11/2026" }], totalCents: 15001 }],
    ["minutos 0", { ...terms, weeks: [{ ...week, cookMinutes: 0 }], totalCents: 15001 }],
    ["desordenadas", { ...terms, weeks: [...terms.weeks].reverse() }],
    ["semanas que no son una lista", { ...terms, weeks: {} }],
  ];
  for (const [name, value] of broken) assert.equal(quoteTermsFromRpc(value), null, name);
});

test("createQuoteResponseFromRpc: el dryRun con el estado de cada fecha, sin presupuesto ni sesiones", () => {
  const dry = {
    dry_run: true,
    quote_id: null,
    request_id: REQUEST_ID,
    client_id: CLIENT_ID,
    hold_until: null,
    weeks: [
      { date: "2026-11-23", start_time: "10:00:00", cook_minutes: 180, status: "ok", suggested_start: "09:00:00", service_cents: 15001, session_id: null },
      { date: "2026-11-30", start_time: null, cook_minutes: 180, status: "closed", suggested_start: null, service_cents: 15000, session_id: null },
    ],
  };
  assert.deepEqual(createQuoteResponseFromRpc(dry), {
    dryRun: true,
    quoteId: null,
    requestId: REQUEST_ID,
    clientId: CLIENT_ID,
    holdUntil: null,
    weeks: [
      { date: "2026-11-23", start: "10:00", cookMinutes: 180, status: "ok", suggestedStart: "09:00", serviceCents: 15001, sessionId: null },
      { date: "2026-11-30", start: null, cookMinutes: 180, status: "closed", suggestedStart: null, serviceCents: 15000, sessionId: null },
    ],
  });
});

test("createQuoteResponseFromRpc: creado, con el presupuesto, el plazo del borrador y cada semana con su sesión (free)", () => {
  const created = {
    dry_run: false,
    quote_id: QUOTE_ID,
    request_id: REQUEST_ID,
    client_id: CLIENT_ID,
    hold_until: "2026-11-17T10:00:00.123456+00:00",
    weeks: [{ date: "2026-11-23", start_time: "10:00", cook_minutes: 180, status: "free", suggested_start: null, service_cents: 15000, session_id: SESSION_A }],
  };
  assert.deepEqual(createQuoteResponseFromRpc(created), {
    dryRun: false,
    quoteId: QUOTE_ID,
    requestId: REQUEST_ID,
    clientId: CLIENT_ID,
    holdUntil: "2026-11-17T10:00:00.123456+00:00",
    weeks: [{ date: "2026-11-23", start: "10:00", cookMinutes: 180, status: "free", suggestedStart: null, serviceCents: 15000, sessionId: SESSION_A }],
  });
  const week = created.weeks[0]!;
  const broken: Array<[string, unknown]> = [
    ["no es un objeto", []],
    ["creado sin presupuesto", { ...created, quote_id: null }],
    ["creado sin plazo", { ...created, hold_until: null }],
    ["creado sin sesión", { ...created, weeks: [{ ...week, session_id: null }] }],
    ["creado sin hora", { ...created, weeks: [{ ...week, start_time: null }] }],
    ["creado con otro estado", { ...created, weeks: [{ ...week, status: "ok" }] }],
    ["dryRun con presupuesto", { ...created, dry_run: true, hold_until: null, weeks: [{ ...week, status: "ok", session_id: null }] }],
    ["dryRun con sesión", { ...created, dry_run: true, quote_id: null, hold_until: null, weeks: [{ ...week, status: "ok" }] }],
    ["estado desconocido", { ...created, weeks: [{ ...week, status: "raro" }] }],
    ["sin semanas", { ...created, weeks: [] }],
    ["pedido que no es un uuid", { ...created, request_id: "x" }],
    ["dry_run que no es booleano", { ...created, dry_run: "no" }],
  ];
  for (const [name, value] of broken) assert.equal(createQuoteResponseFromRpc(value), null, name);
});

test("withdrawQuoteResponseFromRpc: camelCase; otra forma, null", () => {
  assert.deepEqual(withdrawQuoteResponseFromRpc({ quote_id: QUOTE_ID, request_id: REQUEST_ID, already: false, cancelled: 2 }), {
    quoteId: QUOTE_ID,
    requestId: REQUEST_ID,
    already: false,
    cancelled: 2,
  });
  for (const value of [null, { quote_id: QUOTE_ID, request_id: REQUEST_ID, already: "no", cancelled: 0 }, { quote_id: QUOTE_ID, request_id: REQUEST_ID, already: true, cancelled: -1 }]) {
    assert.equal(withdrawQuoteResponseFromRpc(value), null, JSON.stringify(value));
  }
});
