// Tests de la lista de colaboradores que deploy-supabase.yml aplica en producción (secreto
// CHEF_MEMBER_EMAILS). Correr con: npm test.
import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import {
  MAX_MEMBERS,
  MEMBER_EMAIL_PATTERN,
  MemberEmailsError,
  maskEmail,
  parseMemberEmails,
  syncMembersSql,
} from "./chef-members.ts";

const SCRIPT = fileURLToPath(new URL("./chef-members.ts", import.meta.url));
const MIGRATION = readFileSync(new URL("../migrations/20261116190000_chef_members.sql", import.meta.url), "utf8");

/** El error de parseMemberEmails, para mirar su mensaje. */
function failure(raw: string, chefEmail?: string): MemberEmailsError {
  try {
    parseMemberEmails(raw, chefEmail);
  } catch (error) {
    assert.ok(error instanceof MemberEmailsError, `otro tipo de error: ${String(error)}`);
    return error;
  }
  assert.fail(`la lista se aceptó: ${raw}`);
}

test("lista: separada por comas, sin mayúsculas, espacios ni repetidos, en el orden en que viene", () => {
  assert.deepEqual(parseMemberEmails(" Socio@Ejemplo.test,otra.persona+radici@correo.example.it , socio@ejemplo.test,"), [
    { email: "socio@ejemplo.test", masked: "s***@e***.test" },
    { email: "otra.persona+radici@correo.example.it", masked: "o***@c***.it" },
  ]);
  // Pegado en varias líneas o con punto y coma, también.
  assert.deepEqual(
    parseMemberEmails("a@ejemplo.test;\nb@ejemplo.test\r\n").map((member) => member.email),
    ["a@ejemplo.test", "b@ejemplo.test"],
  );
});

test("vacía o sin cargar: ningún colaborador (la lista manda: el despliegue saca a los que había)", () => {
  for (const raw of [undefined, "", "   ", " , ,\n"]) {
    assert.deepEqual(parseMemberEmails(raw), [], JSON.stringify(raw));
  }
});

test("un email inválido corta todo; el mensaje dice cuál por su posición, nunca el texto", () => {
  const cases = [
    "socio@ejemplo.test,x');delete from public.chefs;--@a.it",
    "socio@ejemplo.test,sin-arroba.ejemplo.test",
    "socio@ejemplo.test,a@b",
    "socio@ejemplo.test,a@b.c",
    "socio@ejemplo.test,@ejemplo.test",
    "socio@ejemplo.test,ñandú@ejemplo.test",
    "socio@ejemplo.test,comilla\"@ejemplo.test",
    "socio@ejemplo.test,barra\\@ejemplo.test",
    // % es válido en un email, pero GitHub lo interpreta en ::add-mask:: (y nadie lo usa).
    "socio@ejemplo.test,por%ciento@ejemplo.test",
    `socio@ejemplo.test,${"a".repeat(250)}@ejemplo.test`,
  ];
  for (const raw of cases) {
    const error = failure(raw);
    assert.match(error.message, /^CHEF_MEMBER_EMAILS: el email 2 /, raw);
    const second = raw.split(",")[1] ?? "";
    assert.ok(!error.message.includes(second.slice(0, 6)), `el mensaje no repite lo escrito: ${error.message}`);
    assert.ok(!error.message.includes("socio"), "ni los emails válidos");
  }
});

test(`más de ${MAX_MEMBERS} colaboradores: error (es una lista corta, de gente de confianza)`, () => {
  const many = Array.from({ length: MAX_MEMBERS + 1 }, (_, i) => `p${i}@ejemplo.test`).join(",");
  assert.match(failure(many).message, new RegExp(`más de ${MAX_MEMBERS}`));
  assert.equal(parseMemberEmails(many.split(",").slice(0, MAX_MEMBERS).join(",")).length, MAX_MEMBERS);
});

test("el email de la cocinera (CHEF_LOGIN_EMAIL) no va en la lista: su cuenta nunca se toca", () => {
  const error = failure("socio@ejemplo.test, Evelyn@Ejemplo.test", " evelyn@ejemplo.test ");
  assert.match(error.message, /el email 2 es el de la cocinera/);
  assert.ok(!error.message.includes("evelyn"));
  // Sin CHEF_LOGIN_EMAIL no se puede comparar acá: lo frena la base (chef_email_not_member).
  assert.equal(parseMemberEmails("evelyn@ejemplo.test").length, 1);
});

test("enmascarado: la primera letra, la del dominio y la terminación; nunca el email entero", () => {
  assert.equal(maskEmail("persona.prueba@example.com"), "p***@e***.com");
  assert.equal(maskEmail("a@b.it"), "a***@b***.it");
  assert.equal(maskEmail("x@mail.example.co.uk"), "x***@m***.uk");
});

test("SQL: una sola llamada a private.sync_chef_members con los emails ya validados", () => {
  assert.equal(
    syncMembersSql(["socio@ejemplo.test", "otra@ejemplo.test"]),
    "select private.sync_chef_members(array['socio@ejemplo.test', 'otra@ejemplo.test']::text[]) as result",
  );
  // Lista vacía: la cocina se queda sin colaboradores (null sería un error en la base).
  assert.equal(syncMembersSql([]), "select private.sync_chef_members(array[]::text[]) as result");
  // Nada sin validar llega al SQL, aunque se llame sin pasar por parseMemberEmails.
  for (const email of ["x'@ejemplo.test", "Mayus@ejemplo.test", "a b@ejemplo.test"]) {
    assert.throws(() => syncMembersSql([email]), MemberEmailsError, email);
  }
});

test("la regla del email y el tope son los de la base (private.sync_chef_members)", () => {
  const pattern = /v_pattern\s+constant text := '([^']+)';/.exec(MIGRATION)?.[1];
  assert.equal(pattern, MEMBER_EMAIL_PATTERN, "el mismo patrón en chef-members.ts y en la migración");
  assert.match(MIGRATION, new RegExp(`cardinality\\(v_emails\\) > ${MAX_MEMBERS}\\b`), "el mismo tope");
});

test("línea de comandos (la del workflow): list y sql leen CHEF_MEMBER_EMAILS; con un error, código 2 y sin emails", () => {
  const run = (command: string, env: Record<string, string>): string =>
    execFileSync(process.execPath, [SCRIPT, command], {
      env: { ...process.env, CHEF_MEMBER_EMAILS: "", CHEF_LOGIN_EMAIL: "", ...env },
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
    });

  const list = " Socio@Ejemplo.test ,otra@ejemplo.test";
  assert.deepEqual(JSON.parse(run("list", { CHEF_MEMBER_EMAILS: list })), parseMemberEmails(list));
  assert.deepEqual(JSON.parse(run("list", {})), []);
  assert.equal(run("sql", { CHEF_MEMBER_EMAILS: list }), syncMembersSql(["socio@ejemplo.test", "otra@ejemplo.test"]));
  assert.equal(run("sql", {}), syncMembersSql([]));

  for (const [command, env] of [
    ["list", { CHEF_MEMBER_EMAILS: "socio@ejemplo.test,roto" }],
    ["sql", { CHEF_MEMBER_EMAILS: "socio@ejemplo.test,evelyn@ejemplo.test", CHEF_LOGIN_EMAIL: "evelyn@ejemplo.test" }],
    ["otra", {}],
  ] as const) {
    assert.throws(
      () => run(command, env),
      (error: { status?: number; stdout?: string; stderr?: string }) =>
        error.status === 2 && error.stdout === "" && !/socio|evelyn|roto/.test(error.stderr ?? ""),
      command,
    );
  }
});
