// Tests de lo que deploy-supabase.yml hace con la base de producción. Correr con: npm test.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";

const repo = (path: string): URL => new URL(`../../${path}`, import.meta.url);
const WORKFLOW = readFileSync(repo(".github/workflows/deploy-supabase.yml"), "utf8");

/** El bloque de un paso del workflow: desde su "- name:" hasta el paso siguiente. */
function step(name: string): string {
  const start = WORKFLOW.indexOf(`- name: ${name}`);
  assert.notEqual(start, -1, `no está el paso "${name}"`);
  const next = WORKFLOW.indexOf("\n      - ", start + 1);
  return WORKFLOW.slice(start, next === -1 ? undefined : next);
}

test("migraciones: versión de 14 cifras y ninguna repetida (el CLI la usa como clave)", () => {
  // db start, db reset y db push guardan cada migración en supabase_migrations.schema_migrations con
  // el prefijo numérico como clave primaria. Dos con la misma versión (por ejemplo, de dos ramas que
  // llegan a main) rompen db start en CI, y db push en producción da una por aplicada sin correrla.
  const files = readdirSync(repo("supabase/migrations")).sort();
  const malformed = files.filter((name) => !/^\d{14}_[a-z0-9_]+\.sql$/.test(name));
  assert.deepEqual(malformed, [], "nombre esperado: AAAAMMDDHHMMSS_nombre.sql");

  const byVersion = new Map<string, string>();
  const repeated: string[] = [];
  for (const name of files) {
    const version = name.slice(0, 14);
    const other = byVersion.get(version);
    if (other) repeated.push(`${other} y ${name}`);
    else byVersion.set(version, name);
  }
  assert.deepEqual(repeated, [], "cambiarle la versión a una de las dos (una libre, posterior a la última)");
});

test("cuenta de la cocinera: recibe el horario inicial justo después de promote_to_chef", () => {
  // db push corre antes de que exista la cocinera: en un proyecto nuevo la migración
  // 20261115130100_default_availability.sql no encuentra a nadie y, sin reglas, el calendario de la
  // web no marca ningún día (contrato §11.1). El paso solo llega ahí la primera vez.
  const migrations = WORKFLOW.indexOf("- name: Migraciones (db push)");
  const chefStep = WORKFLOW.indexOf("- name: Cuenta de la cocinera");
  assert.ok(migrations !== -1 && migrations < chefStep, "db push corre antes de crear la cuenta");

  const run = step("Cuenta de la cocinera (solo la primera vez)");
  const promote = run.indexOf("public.promote_to_chef(");
  const schedule = run.indexOf('sql "select private.add_default_availability()');
  assert.notEqual(promote, -1, "el paso llama a promote_to_chef");
  assert.ok(schedule > promote, "después de promote_to_chef, private.add_default_availability()");
});
