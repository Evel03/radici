// Tests de test-clients.ts (al lado): la lista del secreto TEST_CLIENT_EMAILS de las cuentas de prueba.
// Correr con: npm test (raíz).
import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { parseMemberEmails } from "./chef-members.ts";
import {
  MAX_TEST_CLIENTS,
  TEST_EMAIL_PATTERN,
  TestClientEmailsError,
  parseTestClientEmails,
  syncTestClientsSql,
} from "./test-clients.ts";

const SCRIPT = fileURLToPath(new URL("./test-clients.ts", import.meta.url));
const MIGRATION = readFileSync(new URL("../migrations/20261127120000_test_clients.sql", import.meta.url), "utf8");

test("lista: separada por comas (o espacios y saltos de línea), en minúsculas, sin repetidos y en orden", () => {
  assert.deepEqual(parseTestClientEmails(" Nico@Ejemplo.test ;\nprueba+1@ejemplo.test, nico@ejemplo.test "), [
    { email: "nico@ejemplo.test", masked: "n***@e***.test" },
    { email: "prueba+1@ejemplo.test", masked: "p***@e***.test" },
  ]);
});

test("vacía o sin cargar: ninguna cuenta de prueba (la lista manda: el despliegue saca a las que había)", () => {
  assert.deepEqual(parseTestClientEmails(undefined), []);
  assert.deepEqual(parseTestClientEmails(" , \n"), []);
});

test("un email inválido corta todo; el mensaje dice cuál por su posición, nunca el texto", () => {
  for (const bad of ["sin-arroba", "x'@ejemplo.test", "a%b@ejemplo.test", "a/b@ejemplo.test", `${"a".repeat(250)}@ejemplo.test`]) {
    assert.throws(
      () => parseTestClientEmails(`nico@ejemplo.test,${bad}`),
      (error: Error) =>
        error instanceof TestClientEmailsError &&
        error.message.startsWith("TEST_CLIENT_EMAILS: el email 2 no es válido") &&
        !error.message.includes(bad) &&
        !error.message.includes("nico"),
      bad,
    );
  }
});

test("una cuenta de la cocina nunca es de prueba: ni la cocinera ni un colaborador", () => {
  const members = parseMemberEmails("socio@ejemplo.test");
  for (const raw of ["Evelyn@Ejemplo.test", "nico@ejemplo.test socio@ejemplo.test"]) {
    assert.throws(
      () => parseTestClientEmails(raw, "evelyn@ejemplo.test", members),
      (error: Error) =>
        error instanceof TestClientEmailsError && /es de la cocina/.test(error.message) && !/evelyn|socio/.test(error.message),
      raw,
    );
  }
  assert.deepEqual(
    parseTestClientEmails("nico@ejemplo.test", "evelyn@ejemplo.test", members).map((tester) => tester.email),
    ["nico@ejemplo.test"],
  );
});

test(`más de ${MAX_TEST_CLIENTS} cuentas de prueba: error`, () => {
  const many = Array.from({ length: MAX_TEST_CLIENTS + 1 }, (_, i) => `p${i}@ejemplo.test`).join(",");
  assert.throws(() => parseTestClientEmails(many), /más de 10 cuentas de prueba/);
  assert.equal(parseTestClientEmails(many.split(",").slice(1).join(",")).length, MAX_TEST_CLIENTS);
});

test("SQL: una sola llamada a private.sync_test_clients con los emails ya validados", () => {
  assert.equal(
    syncTestClientsSql(["nico@ejemplo.test", "prueba+1@ejemplo.test"]),
    "select private.sync_test_clients(array['nico@ejemplo.test', 'prueba+1@ejemplo.test']::text[]) as result",
  );
  assert.equal(syncTestClientsSql([]), "select private.sync_test_clients(array[]::text[]) as result");
  for (const email of ["x'@ejemplo.test", "Mayus@ejemplo.test", "a b@ejemplo.test"]) {
    assert.throws(() => syncTestClientsSql([email]), TestClientEmailsError, email);
  }
});

test("la regla del email y el tope son los de la base (private.sync_test_clients)", () => {
  const pattern = /v_pattern\s+constant text := '([^']+)';/.exec(MIGRATION)?.[1];
  assert.equal(pattern, TEST_EMAIL_PATTERN, "el mismo patrón en test-clients.ts y en la migración");
  assert.match(MIGRATION, new RegExp(`cardinality\\(v_emails\\) > ${MAX_TEST_CLIENTS}\\b`), "el mismo tope");
});

test("línea de comandos (la del workflow): list y sql leen TEST_CLIENT_EMAILS; con un error, código 2 y sin emails", () => {
  const run = (command: string, env: Record<string, string>): string =>
    execFileSync(process.execPath, [SCRIPT, command], {
      env: { ...process.env, TEST_CLIENT_EMAILS: "", CHEF_LOGIN_EMAIL: "", CHEF_MEMBER_EMAILS: "", ...env },
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
    });

  const list = " Nico@Ejemplo.test ,otra@ejemplo.test";
  assert.deepEqual(JSON.parse(run("list", { TEST_CLIENT_EMAILS: list })), parseTestClientEmails(list));
  assert.deepEqual(JSON.parse(run("list", {})), []);
  assert.equal(run("sql", { TEST_CLIENT_EMAILS: list }), syncTestClientsSql(["nico@ejemplo.test", "otra@ejemplo.test"]));
  assert.equal(run("sql", {}), syncTestClientsSql([]));

  for (const [command, env] of [
    ["list", { TEST_CLIENT_EMAILS: "nico@ejemplo.test,roto" }],
    ["sql", { TEST_CLIENT_EMAILS: "nico@ejemplo.test,evelyn@ejemplo.test", CHEF_LOGIN_EMAIL: "evelyn@ejemplo.test" }],
    ["list", { TEST_CLIENT_EMAILS: "nico@ejemplo.test,socio@ejemplo.test", CHEF_MEMBER_EMAILS: "socio@ejemplo.test" }],
    ["otra", {}],
  ] as const) {
    assert.throws(
      () => run(command, env),
      (error: { status?: number; stdout?: string; stderr?: string }) =>
        error.status === 2 && error.stdout === "" && !/nico|socio|evelyn|roto/.test(error.stderr ?? ""),
      command,
    );
  }
});
