// Tests de las reglas que deciden qué jobs de CI corren en un PR (ci-changes.sh) y de cómo las usan
// ci.yml y deploy-web.yml. Correr con: npm test (raíz).
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const SCRIPT = fileURLToPath(new URL("./ci-changes.sh", import.meta.url));
const CI = readFileSync(new URL("../workflows/ci.yml", import.meta.url), "utf8").replaceAll("\r\n", "\n");
const DEPLOY = readFileSync(new URL("../workflows/deploy-web.yml", import.meta.url), "utf8").replaceAll("\r\n", "\n");

const AREAS = ["quote", "edge", "web", "app", "database"] as const;

function areas(files: string[]): string[] {
  const run = spawnSync("bash", [SCRIPT], { input: files.join("\n") + "\n", encoding: "utf8" });
  assert.equal(run.status, 0, run.stderr);
  const out = Object.fromEntries(run.stdout.trim().split("\n").map((line) => line.split("=")));
  for (const area of AREAS) assert.match(out[area], /^(true|false)$/, area);
  return AREAS.filter((area) => out[area] === "true");
}

test("sin cambios no corre nada", () => {
  assert.deepEqual(areas([]), []);
});

test("solo web (sin i18n): web, sin app ni base", () => {
  assert.deepEqual(areas(["web/src/pages/home.ts", "web/package.json"]), ["web"]);
  assert.deepEqual(areas(["web/public/_headers", "web/src/styles/base.css"]), ["web"]);
});

test("i18n de la web: web, los tests de la raíz (emails.test.ts) y la app (la portada copia sus textos)", () => {
  assert.deepEqual(areas(["web/src/i18n/it.json"]), ["quote", "web", "app"]);
});

test("fotos y HTML de la portada web: web y app (landing_texts_test.dart los compara)", () => {
  assert.deepEqual(areas(["web/src/images/cocina.jpg"]), ["web", "app"]);
  assert.deepEqual(areas(["web/index.html"]), ["web", "app"]);
  assert.deepEqual(areas(["web/vite.config.ts"]), ["web", "app"]);
});

test("solo app/**: app, sin raíz", () => {
  assert.deepEqual(areas(["app/lib/main.dart", "app/pubspec.yaml"]), ["app"]);
});

test("migraciones, tests y config de base: base, raíz y app (sus tests leen las migraciones)", () => {
  assert.deepEqual(areas(["supabase/migrations/20261122000000_x.sql"]), ["quote", "app", "database"]);
  assert.deepEqual(areas(["supabase/tests/database/rls.sql"]), ["quote", "app", "database"]);
  assert.deepEqual(areas(["supabase/config.toml"]), ["quote", "app", "database"]);
  assert.deepEqual(areas(["supabase/seed.sql"]), ["quote", "app", "database"]);
});

test("Edge Functions: deno check, raíz y app; _shared también la web", () => {
  assert.deepEqual(areas(["supabase/functions/chef/index.ts"]), ["quote", "edge", "app"]);
  assert.deepEqual(areas(["supabase/functions/_shared/quote_vectors.json"]), ["quote", "edge", "web", "app"]);
  assert.deepEqual(areas(["supabase/templates/login_code.html"]), ["quote", "app"]);
});

test("cambios en .github (workflows, scripts, dependabot) corren todo", () => {
  const todo = [...AREAS];
  assert.deepEqual(areas([".github/workflows/ci.yml"]), todo);
  assert.deepEqual(areas([".github/scripts/ci-changes.sh"]), todo);
  assert.deepEqual(areas([".github/workflows/deploy-web.yml", "web/src/a.ts"]), todo);
  assert.deepEqual(areas([".github/dependabot.yml"]), todo);
});

test("docs, package.json y archivos sueltos de la raíz: la raíz (ante la duda, corre)", () => {
  assert.deepEqual(areas(["docs/contracts/public-request.md"]), ["quote"]);
  assert.deepEqual(areas(["package.json"]), ["quote"]);
  assert.deepEqual(areas(["SPEC.md", "CLAUDE.md"]), ["quote"]);
  assert.deepEqual(areas(["algo-que-no-existe/x"]), ["quote"]);
});

test("acepta CRLF, nombres con acentos y la ruta vieja y la nueva de un renombre", () => {
  assert.deepEqual(areas(["web/src/a.ts\r", "app/lib/a.dart\r"]), ["web", "app"]);
  assert.deepEqual(areas(["app/assets/Radici — Especificación.md"]), ["app"]);
  assert.deepEqual(areas(["app/lib/viejo.dart", "web/src/nuevo.ts"]), ["web", "app"]);
});

// Lo que los tests leen del repo fuera de su propia carpeta: si cambia, corre el job que lo lee.
test("las dependencias de los tests de la app, la web y la raíz están cubiertas", () => {
  for (const f of [
    "supabase/config.toml",
    "supabase/migrations/20261121100000_menu_sends.sql",
    "supabase/functions/_shared/chef_api.ts",
    "supabase/functions/_shared/public_request.test.ts",
    "supabase/functions/_shared/quote_vectors.json",
    "supabase/functions/_shared/cook_load.ts",
    "web/src/i18n/en.json",
    "web/src/images/tarjeta.jpg",
    "web/index.html",
    "web/vite.config.ts",
  ]) assert.ok(areas([f]).includes("app"), `${f} corre la app`);
  for (const f of ["supabase/functions/_shared/quote.ts", "supabase/functions/_shared/menu.ts"]) {
    assert.ok(areas([f]).includes("web"), `${f} corre la web`);
  }
  for (const f of ["web/src/i18n/es.json", "supabase/templates/login_code.html", "supabase/scripts/auth-config.ts"]) {
    assert.ok(areas([f]).includes("quote"), `${f} corre la raíz`);
  }
});

function job(text: string, name: string): string {
  const start = text.indexOf(`\n  ${name}:\n`);
  assert.notEqual(start, -1, `está el job ${name}`);
  const next = text.slice(start + 1).search(/\n  [\w-]+:\n/);
  return next === -1 ? text.slice(start) : text.slice(start, start + 1 + next);
}

test("ci.yml: cada job pesado depende de «changes» y corre según su área", () => {
  const wanted = { quote: "quote", "edge-functions": "edge", web: "web", app: "app", database: "database" };
  for (const [name, area] of Object.entries(wanted)) {
    const text = job(CI, name);
    assert.match(text, /\n    needs: changes\n/, `${name} espera a changes`);
    assert.ok(text.includes(`if: needs.changes.outputs.${area} == 'true'`), `${name} usa la salida ${area}`);
  }
});

test("ci.yml: «changes» es a prueba de fallos (si no puede calcular el diff, corre todo); en push a main corre todo", () => {
  const changes = job(CI, "changes");
  assert.match(changes, /fetch-depth: 0/);
  assert.match(changes, /if ! git -c core\.quotepath=off diff --name-only --no-renames "\$\{BASE_SHA\}\.\.\.\$\{HEAD_SHA\}" >/);
  assert.match(changes, /if ! areas=\$\(bash \.github\/scripts\/ci-changes\.sh </, "si el script falla, corre todo");
  assert.doesNotMatch(changes, /set -[a-z]*e/, "sin set -e: un fallo no deja las salidas vacías");
  assert.match(changes, /all\(\) \{ printf '%s\\n' quote=true edge=true web=true app=true database=true \| tee -a "\$\{GITHUB_OUTPUT\}"; \}/);
  assert.match(changes, /if \[ "\$\{EVENT\}" != "pull_request" \]; then\n\s+all\n/, "fuera de un PR, todo");
});

test("deploy-web.yml: no corre en los pull requests (solo main y a mano) y desde una rama nunca es producción", () => {
  const on = DEPLOY.slice(DEPLOY.indexOf("\non:\n"), DEPLOY.indexOf("\nconcurrency:"));
  assert.match(on, /push:\n\s+branches: \[main\]/);
  assert.match(on, /workflow_dispatch:/);
  assert.doesNotMatch(on, /pull_request/);
  // Producción se decide por la rama, no por el evento: un dispatch desde otra rama es vista previa.
  assert.match(DEPLOY, /elif \[ "\$\{BRANCH\}" = "main" \]/);
  assert.match(DEPLOY, /--branch=\$\{\{ github\.head_ref \|\| github\.ref_name \}\}/);
  assert.match(DEPLOY, /cancel-in-progress: false/);
});

// Sin dependencia de un parser YAML (la raíz no instala paquetes): lint estructural que habría
// detectado el bloque «run: |» cortado por líneas en columna 0.
function lintYaml(text: string): string[] {
  const errors: string[] = [];
  let blockIndent = -1; // indentación de la clave del bloque «|» abierto, -1 si no hay
  text.split("\n").forEach((line, i) => {
    const n = i + 1;
    if (line.trim() === "") return;
    const indent = line.length - line.trimStart().length;
    if (blockIndent >= 0) {
      if (indent > blockIndent) return;
      blockIndent = -1;
    }
    if (line.includes("\t")) errors.push(`línea ${n}: tabulación`);
    if (indent === 0 && !/^(#|[A-Za-z_][\w-]*:|---)/.test(line)) errors.push(`línea ${n}: texto suelto en columna 0`);
    if (/^\s*(- )?[\w-]+:\s*[|>][+-]?\s*$/.test(line)) blockIndent = indent + (line.trimStart().startsWith("- ") ? 2 : 0);
  });
  return errors;
}

test("los workflows no tienen texto suelto en columna 0 (YAML válido)", () => {
  assert.deepEqual(lintYaml(CI), []);
  assert.deepEqual(lintYaml(DEPLOY), []);
  assert.ok(lintYaml("a:\n  run: |\n    x\nedge=true\n").length > 0, "el lint detecta el error");
});

test("las salidas de «changes» coinciden con las que usan los demás jobs", () => {
  const declared = [...job(CI, "changes").matchAll(/\n      (\w+): \$\{\{ steps\.areas\.outputs\.(\w+) \}\}/g)].map((m) => m[1]);
  assert.deepEqual(declared.sort(), ["app", "database", "edge", "quote", "web"]);
  const used = [...CI.matchAll(/needs\.changes\.outputs\.(\w+)/g)].map((m) => m[1]);
  for (const name of used) assert.ok(declared.includes(name), `la salida ${name} está declarada`);
});

test("el checkout con historia no usa un fetch-depth falsy (0 en «cond && 0 || 1» vale siempre 1)", () => {
  for (const text of [CI, DEPLOY]) assert.doesNotMatch(text, /fetch-depth: \$\{\{[^}]*&& 0 \|\|/);
});
