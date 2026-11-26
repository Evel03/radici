// La lista de ofertas: el link del email, el email enmascarado y la forma de lo que devuelve la base.
import { test } from "node:test";
import assert from "node:assert/strict";
import { MARKETING_PAGE_PATH, MARKETING_ROUTES, marketingPageUrl, marketingStateFromRpc, maskEmail } from "./marketing.ts";

const TOKEN = "b".repeat(43);

test("el link: /preferenze/ en el idioma del pedido, con el token en el fragmento", () => {
  assert.equal(MARKETING_PAGE_PATH, "/preferenze/");
  assert.equal(marketingPageUrl("https://radicicucina.app", "it", TOKEN), `https://radicicucina.app/preferenze/#t=${TOKEN}`);
  assert.equal(marketingPageUrl("https://radicicucina.app/", "es", TOKEN), `https://radicicucina.app/preferenze/?lang=es#t=${TOKEN}`);
  assert.equal(marketingPageUrl("https://radicicucina.app", "en", TOKEN), `https://radicicucina.app/preferenze/?lang=en#t=${TOKEN}`);
});

test("las rutas del link, bajo public-request", () => {
  assert.deepEqual(MARKETING_ROUTES, { status: "/marketing/status", confirm: "/marketing/confirm", withdraw: "/marketing/withdraw" });
});

test("el email enmascarado: la primera letra y el dominio", () => {
  assert.equal(maskEmail("giulia@example.it"), "g***@example.it");
  assert.equal(maskEmail("a@b.it"), "a***@b.it");
  assert.equal(maskEmail("sin-arroba"), "***");
  assert.equal(maskEmail("@example.it"), "***");
});

test("lo que devuelve la base: estado e idioma válidos; si no, null", () => {
  assert.deepEqual(marketingStateFromRpc({ status: "pending", locale: "es", email: "x@y.it" }), { status: "pending", locale: "es", email: "x@y.it" });
  assert.deepEqual(marketingStateFromRpc({ status: "withdrawn", locale: "it" }), { status: "withdrawn", locale: "it", email: null });
  for (const bad of [null, [], "x", { status: "otro", locale: "it" }, { status: "pending", locale: "fr" }]) {
    assert.equal(marketingStateFromRpc(bad), null, JSON.stringify(bad));
  }
});
