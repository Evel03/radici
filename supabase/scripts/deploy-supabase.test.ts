// Tests de lo que deploy-supabase.yml hace con la base de producción. Correr con: npm test.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readdirSync } from "node:fs";

const repo = (path: string): URL => new URL(`../../${path}`, import.meta.url);

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
