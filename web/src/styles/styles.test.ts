// Las hojas de estilo de src/styles/ en los navegadores que declara build.target (vite.config.ts).
import { describe, expect, it } from "vitest";

// La web no tiene @types/node: fs se carga con un import dinámico sin tipos (los tests corren en Node). Los CSS se leen
// del disco: vitest los importa vacíos, también con ?raw.
const fs = (await import("node:fs" as string)) as {
  readdirSync(path: URL): string[];
  readFileSync(path: URL, encoding: "utf8"): string;
};
const dir = new URL("./", import.meta.url);

/** Cada hoja de estilo, como texto y sin comentarios (los comentarios pueden nombrar propiedades). */
const sheets = fs
  .readdirSync(dir)
  .filter((file) => file.endsWith(".css"))
  .map((file) => [file, fs.readFileSync(new URL(file, dir), "utf8").replace(/\/\*[\s\S]*?\*\//g, "")] as const);

describe("el CSS en los navegadores de build.target", () => {
  it("se leen las hojas de verdad (no vacías)", () => {
    expect(sheets.map(([file]) => file)).toEqual(expect.arrayContaining(["base.css", "book.css", "reservation.css"]));
    for (const [file, css] of sheets) expect(css.length, file).toBeGreaterThan(100);
  });

  it("inset, inset-inline e inset-block sin var(): Safari 14.0 no los conoce y el build los baja a top/right/bottom/left solo con valores fijos", () => {
    // Lightning CSS (el minificador de Vite) deja `inset: var(--x)` igual (var() puede traer más de un valor) y Safari
    // 14.0 (iOS hasta 14.4) descarta la declaración entera: la caja pierde su lugar.
    const found = sheets.flatMap(([file, css]) =>
      [...css.matchAll(/(?:^|[;{\s])(inset(?:-inline|-block)?\s*:[^;{}]*\bvar\([^;{}]*)/g)].map((m) => `${file}: ${(m[1] ?? "").trim()}`),
    );
    expect(found).toEqual([]);
  });
});
