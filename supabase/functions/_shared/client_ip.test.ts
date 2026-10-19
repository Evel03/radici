// Tests de la IP del visitante y su hash para el límite por IP. Correr con: npm test.
import { test } from "node:test";
import assert from "node:assert/strict";
import { clientIp, hashSubject, rateLimitSubject } from "./client_ip.ts";

test("cf-connecting-ip manda: Cloudflare la reemplaza por la IP real", () => {
  const headers = new Headers({ "cf-connecting-ip": "203.0.113.7", "x-forwarded-for": "198.51.100.1, 10.0.0.1" });
  assert.equal(clientIp(headers), "203.0.113.7");
  assert.equal(clientIp(new Headers({ "cf-connecting-ip": "2001:DB8::1" })), "2001:db8::1");
});

test("sin cf-connecting-ip: la última de x-forwarded-for (las primeras las puede inventar el cliente)", () => {
  assert.equal(clientIp(new Headers({ "x-forwarded-for": "1.2.3.4, 198.51.100.9" })), "198.51.100.9");
  assert.equal(clientIp(new Headers({ "x-forwarded-for": " 198.51.100.9 " })), "198.51.100.9");
  assert.equal(clientIp(new Headers({ "x-forwarded-for": "198.51.100.9:51234" })), "198.51.100.9", "sin el puerto");
  assert.equal(
    clientIp(new Headers({ "cf-connecting-ip": "no-es-ip", "x-forwarded-for": "198.51.100.9" })),
    "198.51.100.9",
    "un cf-connecting-ip inválido se ignora",
  );
});

test("sin cabeceras o con basura: null", () => {
  assert.equal(clientIp(new Headers()), null);
  assert.equal(clientIp(new Headers({ "x-forwarded-for": "unknown" })), null);
  assert.equal(clientIp(new Headers({ "x-forwarded-for": "999.1.1.1" })), null);
  assert.equal(clientIp(new Headers({ "x-forwarded-for": "1.2.3.4, " })), null, "la última entrada está vacía");
});

test("clave del límite: la IPv4 tal cual; de una IPv6, su /64", () => {
  assert.equal(rateLimitSubject("203.0.113.7"), "203.0.113.7");
  assert.equal(rateLimitSubject("2001:db8:abcd:12:1:2:3:4"), "2001:db8:abcd:12::/64");
  assert.equal(rateLimitSubject("2001:DB8:ABCD:0012::1"), "2001:db8:abcd:12::/64");
  assert.equal(rateLimitSubject("2001:db8::1"), "2001:db8:0:0::/64");
  assert.equal(rateLimitSubject("::1"), "0:0:0:0::/64");
  assert.equal(rateLimitSubject("::ffff:203.0.113.7"), "203.0.113.7", "IPv4 mapeada en IPv6");
  assert.equal(rateLimitSubject("2001:db8:abcd:12:1:2:3:4:5"), "2001:db8:abcd:12:1:2:3:4:5", "inválida: se usa tal cual");
});

test("hashSubject: HMAC-SHA-256 en hexadecimal, con la sal como clave", async () => {
  // Vector conocido de HMAC-SHA-256 (clave "key").
  assert.equal(
    await hashSubject("The quick brown fox jumps over the lazy dog", "key"),
    "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8",
  );
  const first = await hashSubject("203.0.113.7", "sal-1");
  assert.match(first, /^[0-9a-f]{64}$/);
  assert.equal(await hashSubject("203.0.113.7", "sal-1"), first, "estable");
  assert.notEqual(await hashSubject("203.0.113.7", "sal-2"), first, "depende de la sal");
  assert.notEqual(await hashSubject("203.0.113.8", "sal-1"), first);
});
