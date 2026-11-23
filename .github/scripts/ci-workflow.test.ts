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

test("iOS release: manual o PR acotado a sus archivos, la subida solo manual, imagen y Xcode fijos, la clave se borra", () => {
  const text = readFileSync(new URL("ios-release.yml", workflows), "utf8");
  const on = text.slice(text.indexOf("\non:\n"), text.indexOf("\n# Un grupo por rama"));
  assert.match(on, /pull_request:\n\s+paths:/, "el PR corre solo si cambian sus archivos");
  assert.match(on, /workflow_dispatch:/);
  assert.doesNotMatch(on, /push:/, "no corre solo en cada push (los minutos de macOS cuestan)");
  assert.match(text, /runs-on: macos-\d+\n/, "imagen de macOS fija, no macos-latest");
  assert.match(text, /XCODE_VERSION: "\d+\.\d+(\.\d+)?"/, "Xcode fijo");
  const upload = /- name: TestFlight - subir el build\n\s+if: ([^\n]+)/.exec(text)?.[1] ?? "";
  assert.match(upload, /github\.event_name == 'workflow_dispatch'/, "un PR nunca sube");
  assert.match(text, /- name: Borrar la clave[^\n]*\n\s+if: always\(\)/, "la clave .p8 se borra siempre");
  // Los secretos entran por env: nunca dentro de un script (run).
  let runIndent = -1;
  for (const line of text.split("\n")) {
    const indent = line.length - line.trimStart().length;
    if (runIndent >= 0 && line.trim() !== "" && indent <= runIndent) runIndent = -1;
    if (runIndent >= 0) assert.doesNotMatch(line, /\$\{\{\s*secrets\./, `secreto dentro de un run: ${line.trim()}`);
    if (/^\s*run:/.test(line)) runIndent = indent;
  }
});
