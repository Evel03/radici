// Tests de lo que los workflows fijan: las actions por SHA y el job de CI que revisa los tipos de las
// Edge Functions con Deno. Correr con: npm test (raíz).
import { test } from "node:test";
import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";

const workflows = new URL("../workflows/", import.meta.url);
const CI = readFileSync(new URL("ci.yml", workflows), "utf8");

test("todas las actions de los workflows van fijadas por SHA con su « # vX.Y.Z » (Dependabot las actualiza)", () => {
  for (const name of readdirSync(workflows).filter((file) => file.endsWith(".yml"))) {
    const text = readFileSync(new URL(name, workflows), "utf8");
    const uses = text.split("\n").filter((line) => /^\s*(- )?uses: /.test(line));
    assert.ok(uses.length > 0, `${name} usa actions`);
    for (const line of uses) {
      assert.match(line, /uses: [\w.-]+\/[\w.-]+@[0-9a-f]{40} # v\d+\.\d+\.\d+$/, `${name}: ${line.trim()}`);
    }
  }
});

test("CI: deno check de las Edge Functions, con el traductor de chef (que index.ts carga con un import dinámico)", () => {
  const start = CI.indexOf("\n  edge-functions:\n");
  assert.notEqual(start, -1, "está el job edge-functions");
  const next = CI.slice(start + 1).search(/\n  [\w-]+:\n/);
  const job = next === -1 ? CI.slice(start) : CI.slice(start, start + 1 + next);
  assert.match(job, /uses: denoland\/setup-deno@[0-9a-f]{40} # v\d+\.\d+\.\d+/);
  assert.match(job, /deno-version: \d+\.\d+\.\d+$/m, "una versión exacta de Deno");
  const command = /- run: >-\n([\s\S]*?)(?:\n\s*\n|$)/.exec(job)?.[1]?.replace(/\s+/g, " ").trim() ?? "";
  assert.match(command, /^deno check --no-lock --node-modules-dir=none /);
  const files = [
    "supabase/functions/chef/index.ts",
    "supabase/functions/chef/claude_translator.ts",
    "supabase/functions/public-request/index.ts",
    "supabase/functions/menu-reminders/index.ts",
    "supabase/functions/client-link/index.ts",
  ];
  for (const file of files) {
    assert.ok(command.includes(file), `revisa ${file}`);
  }
});

test("CI: deno check revisa el index.ts de cada Edge Function del repo", () => {
  // Una función nueva sin su deno check llegaría a producción sin que nadie revise sus tipos con Deno.
  const functionsDir = new URL("../../supabase/functions/", import.meta.url);
  const functions = readdirSync(functionsDir, { withFileTypes: true })
    .filter((entry) => entry.isDirectory() && !entry.name.startsWith("_"))
    .map((entry) => entry.name);
  assert.ok(functions.includes("client-link"), "está la función client-link");
  for (const name of functions) {
    assert.ok(CI.includes(`supabase/functions/${name}/index.ts`), `deno check de ${name}`);
  }
});

test("CI: «Orden de las migraciones» en cada PR, sobre el merge commit y sin depender de «Qué cambió»", () => {
  const start = CI.indexOf("\n  migrations:\n");
  assert.notEqual(start, -1, "está el job migrations");
  const next = CI.slice(start + 1).search(/\n  [\w-]+:\n/);
  const job = next === -1 ? CI.slice(start) : CI.slice(start, start + 1 + next);
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
