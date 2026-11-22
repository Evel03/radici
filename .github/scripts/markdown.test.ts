// Tests de los documentos del repo (SPEC.md, CLAUDE.md, docs/ y los README): reglas de Markdown que GitHub muestra
// distinto de como se escribieron. Correr con: npm test (raíz).
import { test } from "node:test";
import assert from "node:assert/strict";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = fileURLToPath(new URL("../../", import.meta.url));

/** Los .md del repo, sin node_modules, build ni carpetas ocultas (los de las herramientas). */
function markdownFiles(dir: string, out: string[] = []): string[] {
  for (const name of readdirSync(dir)) {
    if (name.startsWith(".") || name === "node_modules" || name === "build" || name === "dist") continue;
    const path = join(dir, name);
    if (statSync(path).isDirectory()) markdownFiles(path, out);
    else if (name.endsWith(".md")) out.push(path);
  }
  return out;
}

/**
 * Las líneas «---» pegadas debajo de un renglón con texto, fuera de los bloques de código: en CommonMark y GFM ese
 * «---» es el subrayado de un título (setext), así que el párrafo de arriba sale como un título H2 y el separador
 * desaparece. Devuelve el número de cada una (desde 1).
 */
function gluedRules(text: string): number[] {
  const out: number[] = [];
  let fence: string | null = null;
  const lines = text.split(/\r?\n/);
  lines.forEach((line, index) => {
    const marker = /^ {0,3}(`{3,}|~{3,})/.exec(line)?.[1];
    if (marker) {
      if (fence === null) fence = marker[0] ?? null;
      else if (marker[0] === fence) fence = null;
      return;
    }
    if (fence !== null || index === 0 || !/^ {0,3}-+\s*$/.test(line)) return;
    if ((lines[index - 1] ?? "").trim() !== "") out.push(index + 1);
  });
  return out;
}

test("gluedRules: un «---» pegado a un párrafo es un título; con una línea en blanco antes, o en un bloque de código, no", () => {
  assert.deepEqual(gluedRules("# T\n\nUn párrafo.\n---\n\n## 6."), [4]);
  assert.deepEqual(gluedRules("# T\n\nUn párrafo.\n\n---\n\n## 6."), []);
  assert.deepEqual(gluedRules("```\nfoo\n---\n```\n"), []);
  assert.deepEqual(gluedRules("| a | b |\n|---|---|\n| 1 | 2 |\n"), []);
});

test("ningún documento tiene un «---» pegado debajo de un párrafo (GitHub lo mostraría como un título)", () => {
  const files = markdownFiles(ROOT);
  assert.ok(files.some((file) => file.endsWith("SPEC.md")), "lee SPEC.md");
  for (const file of files) {
    assert.deepEqual(gluedRules(readFileSync(file, "utf8")), [], relative(ROOT, file));
  }
});
