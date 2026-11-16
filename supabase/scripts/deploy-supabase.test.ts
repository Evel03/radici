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

test("función chef: se despliega después de las migraciones y de los secretos, con verify_jwt = true", () => {
  // chef llama a las funciones chef_* de la migración de reservas (db push tiene que correr antes) y
  // usa ALLOWED_ORIGINS, que carga el paso de los secretos (contrato chef-api.md §9).
  const migrations = WORKFLOW.indexOf("- name: Migraciones (db push)");
  const secrets = WORKFLOW.indexOf("- name: Secretos de la función");
  const chef = WORKFLOW.indexOf("- name: Desplegar chef");
  assert.ok(migrations !== -1 && secrets !== -1, "están los pasos de las migraciones y de los secretos");
  assert.ok(chef > migrations && chef > secrets, "chef se despliega después de db push y de los secretos");

  const run = step("Desplegar chef");
  assert.match(run, /if: env\.HAS_SUPABASE == 'true'/);
  assert.match(run, /supabase functions deploy chef --project-ref "\$\{SUPABASE_PROJECT_REF\}" --use-api/);
  assert.ok(!run.includes("--no-verify-jwt"), "el chequeo de JWT de la plataforma queda prendido");

  // verify_jwt sale de config.toml: con JWT para chef (la llama la app con la sesión de Evelyn), sin
  // JWT para public-request (la llama gente sin cuenta).
  const config = readFileSync(repo("supabase/config.toml"), "utf8");
  const section = (name: string): string => new RegExp(`\\[functions\\.${name}\\]\\n([\\s\\S]*?)(?:\\n\\[|$)`).exec(config)?.[1] ?? "";
  assert.match(section("chef"), /^enabled = true$/m);
  assert.match(section("chef"), /^verify_jwt = true$/m);
  assert.match(section("public-request"), /^verify_jwt = false$/m);
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
