// Tests de las reglas que deciden qué jobs de CI corren en un PR (ci-changes.sh) y de cómo los
// usan ci.yml y deploy-web.yml. Correr con: npm test (raíz).
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const SCRIPT = fileURLToPath(new URL("./ci-changes.sh", import.meta.url));
const CI = readFileSync(new URL("../workflows/ci.yml", import.meta.url), "utf8").replaceAll("\r\n", "\n");
const DEPLOY = readFileSync(new URL("../workflows/deploy-web.yml", import.meta.url), "utf8").replaceAll("\r\n", "\n");

const AREAS = ["quote", "edge", "web", "app", "database", "gestione"] as const;

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

test("solo web/src (sin i18n): web", () => {
  assert.deepEqual(areas(["web/src/pages/home.ts", "web/package.json"]), ["web"]);
});

test("i18n de la web: web y los tests de la raíz (que los leen)", () => {
  assert.deepEqual(areas(["web/src/i18n/it.json"]), ["quote", "web"]);
});

test("solo app: app y la compilación de /gestione/", () => {
  assert.deepEqual(areas(["app/lib/main.dart", "app/pubspec.yaml"]), ["app", "gestione"]);
});

test("solo migraciones o tests de base: database y raíz", () => {
  assert.deepEqual(areas(["supabase/migrations/20261122000000_x.sql"]), ["quote", "database"]);
  assert.deepEqual(areas(["supabase/tests/database/rls.sql"]), ["quote", "database"]);
  assert.deepEqual(areas(["supabase/config.toml"]), ["quote", "database"]);
  assert.deepEqual(areas(["supabase/seed.sql"]), ["quote", "database"]);
});

test("Edge Functions: deno check y raíz; _shared también la web", () => {
  assert.deepEqual(areas(["supabase/functions/chef/index.ts"]), ["quote", "edge"]);
  assert.deepEqual(areas(["supabase/functions/_shared/quote.ts"]), ["quote", "edge", "web"]);
});

test("los vectores de presupuesto los leen la app, la web y los tests de TS", () => {
  assert.deepEqual(areas(["supabase/functions/_shared/quote_vectors.json"]), ["quote", "edge", "web", "app", "gestione"]);
});

test("cambios en el CI o sus scripts corren todo", () => {
  const todo = [...AREAS];
  assert.deepEqual(areas([".github/workflows/ci.yml"]), todo);
  assert.deepEqual(areas([".github/scripts/ci-changes.sh"]), todo);
  assert.deepEqual(areas([".github/workflows/deploy-web.yml", "web/src/a.ts"]), todo);
});

test("otros archivos de .github, docs y package.json: solo la raíz", () => {
  assert.deepEqual(areas([".github/dependabot.yml"]), ["quote"]);
  assert.deepEqual(areas(["docs/contracts/public-request.md"]), ["quote"]);
  assert.deepEqual(areas(["package.json"]), ["quote"]);
});

test("lo que condiciona /gestione/ desde la web la recompila", () => {
  assert.deepEqual(areas(["web/public/_headers"]), ["web", "gestione"]);
  assert.deepEqual(areas(["web/src/build/headers.ts"]), ["web", "gestione"]);
  assert.deepEqual(areas(["web/vite.config.ts"]), ["web", "gestione"]);
});

test("un archivo suelto en la raíz (SPEC.md) no corre nada pesado", () => {
  assert.deepEqual(areas(["SPEC.md", "CLAUDE.md"]), []);
});

test("acepta saltos de línea CRLF y combina áreas", () => {
  assert.deepEqual(areas(["web/src/a.ts\r", "app/lib/a.dart\r"]), ["web", "app", "gestione"]);
});

function job(text: string, name: string): string {
  const start = text.indexOf(`\n  ${name}:\n`);
  assert.notEqual(start, -1, `está el job ${name}`);
  const next = text.slice(start + 1).search(/\n  [\w-]+:\n/);
  return next === -1 ? text.slice(start) : text.slice(start, start + 1 + next);
}

test("ci.yml: cada job pesado depende de «changes» y corre según su área; en push a main corren todos", () => {
  const wanted = { quote: "quote", "edge-functions": "edge", web: "web", app: "app", database: "database" };
  for (const [name, area] of Object.entries(wanted)) {
    const text = job(CI, name);
    assert.match(text, /\n    needs: changes\n/, `${name} espera a changes`);
    assert.ok(text.includes(`if: needs.changes.outputs.${area} == 'true'`), `${name} usa la salida ${area}`);
  }
  const changes = job(CI, "changes");
  assert.match(changes, /fetch-depth: 0/);
  assert.match(changes, /git diff --name-only "\$\{BASE_SHA\}\.\.\.\$\{HEAD_SHA\}"/);
  assert.match(changes, /ci-changes\.sh/);
  // Fuera de un PR todas las salidas son true.
  assert.match(changes, /else\n\s+printf 'quote=true\nedge=true\nweb=true\napp=true\ndatabase=true\n'/);
});

test("deploy-web.yml: la vista previa sin cambios en la app no compila Flutter; producción siempre", () => {
  const decide = DEPLOY.slice(DEPLOY.indexOf("- name: Decidir si se compila /gestione/"));
  assert.match(decide, /build_app=true\n\s+if \[ "\$\{EVENT\}" = "pull_request" \]/, "por defecto se compila");
  assert.match(decide, /ci-changes\.sh/);
  const gated = [
    "uses: subosito/flutter-action",
    "- name: App - dependencias y código generado",
    "- name: App - análisis y tests",
    "- name: App - id del build",
    "- name: App - build web para /gestione/",
    "- name: Copiar /gestione/ al sitio",
  ];
  for (const marker of gated) {
    const at = DEPLOY.indexOf(marker);
    assert.notEqual(at, -1, marker);
    const step = DEPLOY.slice(DEPLOY.lastIndexOf("\n      - ", at), DEPLOY.indexOf("\n      - ", at + 5));
    assert.ok(step.includes("if: env.BUILD_APP == 'true'"), `${marker} solo si BUILD_APP`);
  }
  assert.match(DEPLOY, /- name: Página de aviso en \/gestione\/[^\n]*\n\s+if: env\.BUILD_APP != 'true'/);
  assert.match(DEPLOY, /fetch-depth: \$\{\{ github\.event_name == 'pull_request' && 0 \|\| 1 \}\}/);
});
