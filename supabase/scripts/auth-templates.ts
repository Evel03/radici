// Escribe (o comprueba) las plantillas de los emails de Supabase Auth en supabase/templates/ a partir de la fuente única,
// supabase/functions/_shared/auth_emails.ts (contrato docs/contracts/auth.md §13). config.toml las usa en local y
// auth-config.ts las manda a producción: ninguna se edita a mano.
//
// Uso (desde la raíz): node supabase/scripts/auth-templates.ts          (las escribe)
//                      node supabase/scripts/auth-templates.ts --check  (falla con 1 si alguna no coincide)
// Solo sintaxis borrable: corre con node, sin compilar.
import { readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { AUTH_EMAIL_KINDS, TEMPLATE_FILES, goTrueTemplate } from "../functions/_shared/auth_emails.ts";

const TEMPLATES_DIR = new URL("../templates/", import.meta.url);

/** Las plantillas que no coinciden con la fuente (nombres de archivo). */
export function staleTemplates(read: (file: string) => string | null): string[] {
  return AUTH_EMAIL_KINDS.filter((kind) => read(TEMPLATE_FILES[kind]) !== goTrueTemplate(kind)).map((kind) => TEMPLATE_FILES[kind]);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const read = (file: string): string | null => {
    try {
      return readFileSync(new URL(file, TEMPLATES_DIR), "utf8");
    } catch {
      return null;
    }
  };
  if (process.argv.includes("--check")) {
    const stale = staleTemplates(read);
    if (stale.length > 0) {
      process.stderr.write(`Plantillas de Auth desactualizadas: ${stale.join(", ")}. Correr: node supabase/scripts/auth-templates.ts\n`);
      process.exit(1);
    }
  } else {
    for (const kind of AUTH_EMAIL_KINDS) writeFileSync(new URL(TEMPLATE_FILES[kind], TEMPLATES_DIR), goTrueTemplate(kind));
    process.stdout.write(`Escritas: ${AUTH_EMAIL_KINDS.map((kind) => TEMPLATE_FILES[kind]).join(", ")}\n`);
  }
}
