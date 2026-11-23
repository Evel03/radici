// Tests de migration-order.ts: el orden de las migraciones de un PR contra main (db push corre sin
// --include-all). Correr con: npm test (raíz).
import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { checkMigrationOrder, escapeAnnotation } from "./migration-order.ts";

const DIR = "supabase/migrations/";
const m = (name: string) => `${DIR}${name}`;
const MAIN = [m("20261121110000_menu_reminders.sql"), m("20261121120000_quotes.sql")];

function problems(base: readonly string[], merged: readonly string[], modified: readonly string[] = []) {
  return checkMigrationOrder({ base, merged, modified });
}

test("una migración nueva posterior a la última de main pasa", () => {
  assert.deepEqual(problems(MAIN, [...MAIN, m("20261123100000_client_rls_lockdown.sql")]), []);
});

test("una migración nueva con la misma versión que la última de main falla", () => {
  const found = problems(MAIN, [...MAIN, m("20261121120000_otra.sql")]);
  assert.equal(found.length, 1);
  assert.equal(found[0].file, m("20261121120000_otra.sql"));
  assert.match(found[0].message, /20261121120000_quotes\.sql/, "nombra la última de main");
  assert.match(found[0].message, /--include-all/);
});

test("una migración nueva más vieja que la última de main falla, aunque vaya antes de otra nueva que sí es posterior", () => {
  const found = problems(MAIN, [...MAIN, m("20261121115959_vieja.sql"), m("20261123100000_nueva.sql")]);
  assert.deepEqual(found.map((p) => p.file), [m("20261121115959_vieja.sql")]);
});

test("renombrar la migración propia (todavía no mergeada) a una versión posterior pasa: para main es una nueva", () => {
  // La rama tenía 20261121115000_x.sql; main avanzó y la rama la renombró a una versión libre posterior.
  assert.deepEqual(problems(MAIN, [...MAIN, m("20261123110000_x.sql")]), []);
});

test("sin migraciones nuevas, o sin carpeta de migraciones, pasa", () => {
  assert.deepEqual(problems(MAIN, MAIN), []);
  assert.deepEqual(problems([], []), []);
  assert.deepEqual(problems([], [m("20261123100000_primera.sql")]), [], "la primera migración del repo");
});

test("dos migraciones con la misma versión fallan (Supabase guarda una fila por versión)", () => {
  const found = problems(MAIN, [...MAIN, m("20261123100000_a.sql"), m("20261123100000_b.sql")]);
  assert.equal(found.length, 1);
  assert.match(found[0].message, /20261123100000_a\.sql/);
  assert.match(found[0].message, /20261123100000_b\.sql/);
});

test("borrar o renombrar una migración de main falla: producción ya la aplicó", () => {
  const deleted = problems(MAIN, [MAIN[0]]);
  assert.deepEqual(deleted.map((p) => p.file), [MAIN[1]]);
  assert.match(deleted[0].message, /producción/);

  const renamed = problems(MAIN, [MAIN[0], m("20261123100000_quotes.sql")]);
  assert.deepEqual(renamed.map((p) => p.file), [MAIN[1]], "el nombre nuevo es posterior, pero el viejo ya está aplicado");
});

test("cambiar una migración de main falla: producción no la vuelve a correr", () => {
  const found = problems(MAIN, MAIN, [MAIN[1]]);
  assert.deepEqual(found.map((p) => p.file), [MAIN[1]]);
  assert.match(found[0].message, /migración nueva/);
});

test("los archivos que no son .sql se ignoran; un .sql con otro nombre falla (el CLI de Supabase lo saltea)", () => {
  assert.deepEqual(problems(MAIN, [...MAIN, m(".gitkeep"), m("README.md")]), []);
  for (const name of ["agregar_columna.sql", "2026112310000_corta.sql", "202611231000000_larga.sql", "20261123100000-guion.sql", "20261123100000_mayusculas.SQL", "20261123100000_.sql"]) {
    const found = problems(MAIN, [...MAIN, m(name)]);
    assert.deepEqual(found.map((p) => p.file), [m(name)], name);
    assert.match(found[0].message, /AAAAMMDDHHMMSS_nombre\.sql/, name);
  }
});

test("el mensaje de nombre inválido distingue lo que el CLI saltea de lo que aplicaría con otra cantidad de dígitos", () => {
  assert.match(problems(MAIN, [...MAIN, m("2026112310000_corta.sql")])[0].message, /el CLI lo aplicaría/);
  assert.match(problems(MAIN, [...MAIN, m("agregar_columna.sql")])[0].message, /el CLI de Supabase saltea/);
});

test("una migración de main con prefijo que no es de 14 dígitos igual cuenta como aplicada", () => {
  const odd = [...MAIN, m("2026_x.sql")];
  assert.deepEqual(problems(odd, MAIN).map((p) => p.file), [m("2026_x.sql")]);
  assert.deepEqual(problems(odd, odd, [m("2026_x.sql")]).map((p) => p.file), [m("2026_x.sql")]);
});

test("solo cuenta lo de supabase/migrations/ (sin subcarpetas)", () => {
  assert.deepEqual(problems(MAIN, [...MAIN, `${DIR}viejas/20200101000000_x.sql`, "supabase/seed.sql"]), []);
});

test("los avisos de GitHub escapan %, saltos de línea y, en las propiedades, : y ,", () => {
  assert.equal(escapeAnnotation("50%\r\nlisto", false), "50%25%0D%0Alisto");
  assert.equal(escapeAnnotation("a:b,c", true), "a%3Ab%2Cc");
});

// ---------------------------------------------------------------------------
// El script de verdad, sobre un repo de git armado para el test
// ---------------------------------------------------------------------------

const SCRIPT = fileURLToPath(new URL("./migration-order.ts", import.meta.url));

function makeRepo(): { dir: string; git: (...args: string[]) => string; write: (name: string, text?: string) => void } {
  const dir = mkdtempSync(join(tmpdir(), "radici-migraciones-"));
  // Sin la configuración global de quien corre el test (firma de commits, rama por defecto, autocrlf).
  const env = { ...process.env, GIT_CONFIG_GLOBAL: join(dir, ".sin-config-global"), GIT_CONFIG_NOSYSTEM: "1" };
  const git = (...args: string[]) =>
    execFileSync("git", ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false", ...args], {
      cwd: dir,
      env,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
    });
  const write = (name: string, text = "select 1;\n") => {
    mkdirSync(join(dir, DIR), { recursive: true });
    writeFileSync(join(dir, DIR, name), text);
  };
  git("init", "-q", "-b", "main");
  return { dir, git, write };
}

function runScript(dir: string, ...args: string[]) {
  const env = { ...process.env, GIT_CONFIG_GLOBAL: join(dir, ".sin-config-global"), GIT_CONFIG_NOSYSTEM: "1" };
  return spawnSync(process.execPath, [SCRIPT, ...args], { cwd: dir, env, encoding: "utf8" });
}

test("en el CI (HEAD = merge commit del PR, HEAD^1 = main): una rama atrasada con una migración vieja falla", (t) => {
  const repo = makeRepo();
  t.after(() => rmSync(repo.dir, { recursive: true, force: true }));
  repo.write("20261121110000_menu_reminders.sql");
  repo.git("add", ".");
  repo.git("commit", "-q", "-m", "main");
  // La rama sale de acá y suma su migración...
  repo.git("checkout", "-q", "-b", "rama");
  repo.write("20261121115000_de_la_rama.sql");
  repo.git("add", ".");
  repo.git("commit", "-q", "-m", "rama");
  // ...mientras main suma otra posterior (otro PR que se mergeó antes).
  repo.git("checkout", "-q", "main");
  repo.write("20261121120000_quotes.sql");
  repo.git("add", ".");
  repo.git("commit", "-q", "-m", "otro PR");
  // GitHub arma el merge commit con main como primer padre y la rama como segundo.
  repo.git("merge", "-q", "--no-ff", "-m", "merge del PR", "rama");

  const result = runScript(repo.dir);
  assert.equal(result.status, 1, result.stdout + result.stderr);
  assert.match(result.stdout, /^::error file=supabase\/migrations\/20261121115000_de_la_rama\.sql,title=/m);
  assert.match(result.stdout, /20261121120000_quotes\.sql/);
});

test("en el CI: una rama con una migración posterior pasa, y un commit que no es un merge corta con un aviso claro", (t) => {
  const repo = makeRepo();
  t.after(() => rmSync(repo.dir, { recursive: true, force: true }));
  repo.write("20261121120000_quotes.sql");
  repo.git("add", ".");
  repo.git("commit", "-q", "-m", "main");

  const notMerge = runScript(repo.dir);
  assert.equal(notMerge.status, 2, notMerge.stdout + notMerge.stderr);
  assert.match(notMerge.stdout, /^::error title=[^:]+::.*merge commit/m);

  repo.git("checkout", "-q", "-b", "rama");
  repo.write("20261123100000_nueva con espacio y acentuación.sql");
  repo.git("add", ".");
  repo.git("commit", "-q", "-m", "rama");
  repo.git("checkout", "-q", "main");
  repo.git("merge", "-q", "--no-ff", "-m", "merge del PR", "rama");

  const ok = runScript(repo.dir);
  assert.equal(ok.status, 0, ok.stdout + ok.stderr);
  assert.match(ok.stdout, /1 nueva/);
});

test("en local, contra una rama base: simula el merge (como GitHub) y detecta una migración de main editada", (t) => {
  const repo = makeRepo();
  t.after(() => rmSync(repo.dir, { recursive: true, force: true }));
  repo.write("20261121120000_quotes.sql");
  repo.git("add", ".");
  repo.git("commit", "-q", "-m", "main");
  repo.git("checkout", "-q", "-b", "rama");
  repo.write("20261121120000_quotes.sql", "select 2; -- editada\n");
  repo.write("20261123100000_nueva.sql");
  repo.git("add", ".");
  repo.git("commit", "-q", "-m", "rama");

  const result = runScript(repo.dir, "main");
  assert.equal(result.status, 1, result.stdout + result.stderr);
  assert.match(result.stdout, /^::error file=supabase\/migrations\/20261121120000_quotes\.sql,title=/m);
  assert.doesNotMatch(result.stdout, /20261123100000_nueva\.sql,title=/, "la nueva está bien");

  repo.git("checkout", "-q", "main");
  repo.git("checkout", "-q", "-b", "limpia");
  repo.write("20261123100000_nueva.sql");
  repo.git("add", ".");
  repo.git("commit", "-q", "-m", "limpia");
  const clean = runScript(repo.dir, "main");
  assert.equal(clean.status, 0, clean.stdout + clean.stderr);
});

// ---------------------------------------------------------------------------
// Dónde corre: el job de ci.yml y el db push de deploy-supabase.yml (acá y no en ci-workflow.test.ts, así
// este PR no choca con otros que suman tests de workflows)
// ---------------------------------------------------------------------------

const workflows = new URL("../workflows/", import.meta.url);

test("CI: «Orden de las migraciones» en cada PR, sobre el merge commit y sin depender de «Qué cambió»", () => {
  const ci = readFileSync(new URL("ci.yml", workflows), "utf8");
  const start = ci.indexOf("\n  migrations:\n");
  assert.notEqual(start, -1, "está el job migrations");
  const next = ci.slice(start + 1).search(/\n  [\w-]+:\n/);
  const job = next === -1 ? ci.slice(start) : ci.slice(start, start + 1 + next);
  assert.match(job, /\n    if: github\.event_name == 'pull_request'\n/, "solo en los PR (en main no hay merge commit que comparar)");
  assert.doesNotMatch(job, /\n    needs:/, "no depende de «Qué cambió»: un error ahí no lo saltea");
  assert.match(job, /\n          fetch-depth: 2\n/, "el merge commit y sus dos padres");
  assert.doesNotMatch(job, /\n          ref:/, "el merge commit del PR: el ref por defecto de actions/checkout");
  assert.match(job, /\n          node-version: 24\n/);
  assert.match(job, /\n      - run: node \.github\/scripts\/migration-order\.ts\n/);
});

test("deploy-supabase: db push sin --include-all (el orden de las migraciones lo cuida el CI)", () => {
  const deploy = readFileSync(new URL("deploy-supabase.yml", workflows), "utf8");
  const pushes = deploy.split("\n").filter((line) => /^\s*run: .*supabase db push/.test(line));
  assert.deepEqual(pushes.map((line) => line.trim()), ["run: supabase db push --yes"]);
  assert.doesNotMatch(deploy, /--include-all/);
});
