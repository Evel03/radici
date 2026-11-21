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
  for (const file of ["supabase/functions/chef/index.ts", "supabase/functions/chef/claude_translator.ts", "supabase/functions/public-request/index.ts"]) {
    assert.ok(command.includes(file), `revisa ${file}`);
  }
});
