// Tests de las piezas comunes de las Edge Functions. Correr con: npm test (node --test).
// resolveServiceKey y safeDbMessage también se prueban desde public-request/handler.test.ts.
import { test } from "node:test";
import assert from "node:assert/strict";
import { StoreError, isJsonContentType, logStoreError, readBodyLimited, type LogFields } from "./edge.ts";

function request(body: BodyInit | null, headers: Record<string, string> = {}): Request {
  return new Request("http://localhost/x", { method: "POST", headers, body });
}

test("isJsonContentType: application/json con o sin charset, sin distinguir mayúsculas", () => {
  assert.ok(isJsonContentType("application/json"));
  assert.ok(isJsonContentType("Application/JSON; charset=UTF-8"));
  for (const value of [null, "", "text/plain", "application/jsonx", "multipart/form-data"]) {
    assert.ok(!isJsonContentType(value), String(value));
  }
});

test("readBodyLimited: corta por Content-Length o leyendo, y rechaza UTF-8 inválido", async () => {
  assert.deepEqual(await readBodyLimited(request('{"a":1}'), 16), { ok: true, text: '{"a":1}' });
  assert.deepEqual(await readBodyLimited(request(null), 16), { ok: true, text: "" });
  assert.deepEqual(await readBodyLimited(request("x", { "content-length": "17" }), 16), { ok: false, reason: "tooLarge" });
  assert.deepEqual(await readBodyLimited(request("x".repeat(17)), 16), { ok: false, reason: "tooLarge" });
  assert.deepEqual(await readBodyLimited(request(new Uint8Array([0x7b, 0xff, 0x7d])), 16), { ok: false, reason: "invalid" });
  assert.deepEqual(await readBodyLimited(request("ñ"), 2), { ok: true, text: "ñ" }, "el límite es en bytes: ñ son 2");
});

test("StoreError: sin detalle por defecto; logStoreError deja solo operación y códigos", () => {
  const plain = new StoreError("submit", "23514", null);
  assert.equal(plain.safeDetail, null);
  assert.equal(plain.message, "db_error:submit");

  const logs: Array<{ event: string; fields: LogFields | undefined }> = [];
  const log = (_level: string, event: string, fields?: LogFields) => logs.push({ event, fields });
  logStoreError(log, new StoreError("create_booking", "23P01", "slot_taken", "2026-11-30"), "otra");
  logStoreError(log, new StoreError("load_chef", "42501", null), "load_chef");
  logStoreError(log, new Error("Maria Rossi, Via Roma 1"), "cancel_sessions");
  assert.deepEqual(logs, [
    { event: "db_error", fields: { op: "create_booking", code: "23P01", message: "slot_taken" } },
    { event: "db_error", fields: { op: "load_chef", code: "42501" } },
    { event: "db_error", fields: { op: "cancel_sessions", code: null } },
  ]);
});
