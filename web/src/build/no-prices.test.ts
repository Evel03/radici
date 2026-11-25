import { describe, expect, it } from "vitest";

// La web pública no muestra precios ni lleva las tarifas en el bundle (decisión del 22/11/2026): Evelyn escribe
// a mano el precio de cada presupuesto. Este test recorre los módulos que alcanza cada página (lo que Vite
// empaqueta) y comprueba que ninguno trae el motor de precios (quote.ts, con DEFAULT_PRICING) ni formatea importes.
const HERE = "/web/src/build/no-prices.test.ts";
const globbed = {
  ...import.meta.glob<string>("../**/*.ts", { query: "?raw", import: "default", eager: true }),
  ...import.meta.glob<string>("../../../supabase/functions/_shared/*.ts", { query: "?raw", import: "default", eager: true }),
};
/** Las rutas de import.meta.glob son relativas a este archivo: todas pasan a una ruta única, «/web/src/…». */
const sources: Record<string, string> = Object.fromEntries(Object.entries(globbed).map(([key, source]) => [resolveSpec(HERE, key), source]));
const ENTRIES = ["landing", "richiesta", "privacy", "prenotazione", "captcha", "not-found"].map((page) => `/web/src/pages/${page}.ts`);

/** Resuelve un import relativo contra el módulo que lo escribe (rutas con «/», como las de import.meta.glob). */
function resolveSpec(from: string, spec: string): string {
  const parts = from.split("/").slice(0, -1);
  for (const part of spec.split("/")) {
    if (part === "..") parts.pop();
    else if (part !== ".") parts.push(part);
  }
  return parts.join("/");
}

/** Los módulos a los que llega cada punto de entrada con imports relativos (estáticos o dinámicos). */
function reachable(entries: string[]): Map<string, string> {
  const seen = new Map<string, string>();
  const queue = [...entries];
  while (queue.length > 0) {
    const file = queue.pop() as string;
    const source = sources[file];
    if (seen.has(file) || source === undefined) continue;
    seen.set(file, source);
    for (const [, spec = ""] of source.matchAll(/(?:from|import)\s*\(?\s*["'](\.{1,2}\/[^"']+)["']/g)) {
      queue.push(resolveSpec(file, spec));
    }
  }
  return seen;
}

describe("la web pública no lleva precios", () => {
  const modules = reachable(ENTRIES);
  const files = [...modules.keys()];

  it("recorre los módulos de las páginas (el recorrido no está vacío y llega a la carga de cocina)", () => {
    expect(files.length).toBeGreaterThan(20);
    expect(files.some((file) => file.endsWith("/_shared/cook_load.ts"))).toBe(true);
    expect(files.some((file) => file.endsWith("/pages/richiesta.ts"))).toBe(true);
  });

  it("ninguna página alcanza el motor de precios (quote.ts) ni los emails", () => {
    expect(files.filter((file) => file.endsWith("/_shared/quote.ts"))).toEqual([]);
    expect(files.filter((file) => file.endsWith("/_shared/emails.ts"))).toEqual([]);
  });

  // Solo la página de la reserva muestra un importe: el precio que Evelyn escribió en el presupuesto de esa clienta.
  const QUOTE_MODULES = ["/web/src/lib/format.ts", "/web/src/reservation/render.ts", "/supabase/functions/_shared/client_link.ts", "/supabase/functions/_shared/quote_snapshot.ts"];

  it("ningún módulo menciona las tarifas ni el ahorro", () => {
    const offending = [...modules.entries()]
      .filter(([, source]) => /DEFAULT_PRICING|weeklyRate|weeklyServiceCents|savingsCents/.test(source))
      .map(([file]) => file)
      .filter((file) => !file.endsWith(".test.ts"));
    expect(offending).toEqual([]);
  });

  it("solo los módulos del presupuesto de la página de la reserva formatean importes", () => {
    const offending = [...modules.entries()]
      .filter(([, source]) => /formatCents|serviceCents|currency:\s*["']EUR/.test(source))
      .map(([file]) => file)
      .filter((file) => !file.endsWith(".test.ts") && !QUOTE_MODULES.includes(file));
    expect(offending).toEqual([]);
  });

  it("ninguna otra página (landing, formulario, privacy) alcanza esos módulos", () => {
    for (const page of ["landing", "richiesta", "privacy", "not-found"]) {
      const reached = [...reachable([`/web/src/pages/${page}.ts`]).keys()];
      expect(reached.filter((file) => QUOTE_MODULES.includes(file) && file !== "/web/src/lib/format.ts"), page).toEqual([]);
    }
  });
});
