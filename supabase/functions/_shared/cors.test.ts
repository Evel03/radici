// Tests de CORS con lista de orígenes permitidos. Correr con: npm test (node --test).
import { test } from "node:test";
import assert from "node:assert/strict";
import { CORS_ALLOWED_HEADERS, corsHeaders, isOriginAllowed, parseAllowedOrigins } from "./cors.ts";

// La lista de ALLOWED_ORIGINS del contrato (§4), con espacios y entradas inválidas.
const RULES = parseAllowedOrigins(
  " https://mestolo.sepusola10.com, https://mestolo-dsa.pages.dev,https://*.mestolo-dsa.pages.dev ,http://localhost:5173,," +
    "no es una url,ftp://x.example,https://*.*.example,https://ejemplo.com/ruta,*",
);

function corsKeys(headers: Record<string, string>): string[] {
  return Object.keys(headers).filter((name) => name.toLowerCase().startsWith("access-control-"));
}

test("parsea la lista del contrato e ignora entradas vacías o inválidas", () => {
  assert.equal(RULES.length, 4);
  assert.deepEqual(parseAllowedOrigins(undefined), []);
  assert.deepEqual(parseAllowedOrigins(""), []);
});

test("orígenes exactos: esquema, host y puerto", () => {
  assert.ok(isOriginAllowed("https://mestolo.sepusola10.com", RULES));
  assert.ok(isOriginAllowed("https://MESTOLO.sepusola10.com", RULES), "el host no distingue mayúsculas");
  assert.ok(isOriginAllowed("http://localhost:5173", RULES));
  assert.ok(!isOriginAllowed("http://localhost:5174", RULES), "otro puerto");
  assert.ok(!isOriginAllowed("http://mestolo.sepusola10.com", RULES), "otro esquema");
  assert.ok(!isOriginAllowed("https://mestolo.sepusola10.com.evil.example", RULES));
  assert.ok(!isOriginAllowed("https://evilmestolo.sepusola10.com", RULES));
  assert.ok(!isOriginAllowed("https://x.mestolo.sepusola10.com", RULES), "una regla exacta no cubre subdominios");
});

test("Origin con formato raro o ausente: no se permite", () => {
  for (const origin of [null, undefined, "", "null", "https://mestolo.sepusola10.com/", "https://mestolo.sepusola10.com/x",
    "mestolo.sepusola10.com", "https://user@mestolo.sepusola10.com", "https://mestolo.sepusola10.com:99999"]) {
    assert.ok(!isOriginAllowed(origin, RULES), `no debería permitir ${String(origin)}`);
  }
});

test("comodín de subdominio: una sola etiqueta, mismo esquema y puerto", () => {
  assert.ok(isOriginAllowed("https://abc123.mestolo-dsa.pages.dev", RULES));
  assert.ok(isOriginAllowed("https://feature-x.mestolo-dsa.pages.dev", RULES));
  assert.ok(isOriginAllowed("https://mestolo-dsa.pages.dev", RULES), "el dominio pelado está en la lista");
  assert.ok(!isOriginAllowed("https://a.b.mestolo-dsa.pages.dev", RULES), "más de una etiqueta");
  assert.ok(!isOriginAllowed("https://evil-mestolo-dsa.pages.dev", RULES));
  assert.ok(!isOriginAllowed("https://abc.mestolo-dsa.pages.dev.evil.example", RULES));
  assert.ok(!isOriginAllowed("http://abc.mestolo-dsa.pages.dev", RULES));
  assert.ok(!isOriginAllowed("https://abc.mestolo-dsa.pages.dev:8443", RULES));

  const onlyWildcard = parseAllowedOrigins("https://*.example.com");
  assert.ok(!isOriginAllowed("https://example.com", onlyWildcard), "el comodín no incluye el dominio pelado");
  assert.ok(!isOriginAllowed("https://.example.com", onlyWildcard));
});

test("el puerto por defecto escrito en la regla equivale a no escribirlo", () => {
  assert.ok(isOriginAllowed("https://example.com", parseAllowedOrigins("https://example.com:443")));
  assert.ok(isOriginAllowed("http://example.com", parseAllowedOrigins("http://example.com:80/")));
});

test("preflight de un origen permitido: método, cabeceras y caché", () => {
  const headers = corsHeaders("https://abc.mestolo-dsa.pages.dev", RULES, { preflight: true });
  assert.equal(headers["Access-Control-Allow-Origin"], "https://abc.mestolo-dsa.pages.dev");
  assert.equal(headers["Access-Control-Allow-Methods"], "POST, OPTIONS");
  assert.equal(headers["Access-Control-Allow-Headers"], CORS_ALLOWED_HEADERS);
  for (const name of ["content-type", "apikey", "authorization", "x-client-info"]) {
    assert.ok(CORS_ALLOWED_HEADERS.split(", ").includes(name), `falta ${name}`);
  }
  assert.equal(headers["Access-Control-Max-Age"], "86400");
  assert.equal(headers["Vary"], "Origin");
});

test("respuesta normal a un origen permitido: expone Retry-After", () => {
  const headers = corsHeaders("http://localhost:5173", RULES, { preflight: false });
  assert.equal(headers["Access-Control-Allow-Origin"], "http://localhost:5173");
  assert.equal(headers["Access-Control-Expose-Headers"], "Retry-After");
  assert.equal(headers["Access-Control-Allow-Methods"], undefined);
  assert.equal(headers["Vary"], "Origin");
});

test("origen no permitido o sin Origin: ninguna cabecera CORS", () => {
  assert.deepEqual(corsKeys(corsHeaders("https://evil.example", RULES, { preflight: true })), []);
  assert.deepEqual(corsKeys(corsHeaders(null, RULES, { preflight: false })), []);
  assert.equal(corsHeaders("https://evil.example", RULES, { preflight: false })["Vary"], "Origin");
});
