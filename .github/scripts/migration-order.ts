// Orden de las migraciones de un PR contra main. deploy-supabase.yml corre `supabase db push` sin
// --include-all, y producción tiene aplicadas todas las migraciones de main: el despliegue que sigue al
// merge falla (o deja algo sin aplicar) si el PR
// - suma una migración con una versión que no es posterior a la última de main (db push la rechaza);
// - borra o renombra una migración de main (db push no encuentra en el repo una versión ya aplicada);
// - cambia una migración de main (producción nunca la vuelve a correr: el cambio no llegaría);
// - suma dos migraciones con la misma versión, o un .sql con un nombre que el CLI de Supabase saltea.
// Dos PRs abiertos pueden estar bien cada uno y chocar cuando se mergea el primero: por eso se compara
// con el main sobre el que se mezcla el PR, no con el punto de donde salió la rama.
//
// Uso:
// - CI (job «Orden de las migraciones» de ci.yml): `node .github/scripts/migration-order.ts`. En un
//   pull_request, actions/checkout baja el merge commit que arma GitHub (HEAD); con fetch-depth: 2 está
//   también su primer padre (HEAD^1), la punta de main sobre la que se mezcla.
// - Local: `node .github/scripts/migration-order.ts origin/main`. Simula ese merge con
//   `git merge-tree` (no toca el árbol de trabajo) y compara igual.
// Sale con 0 si está todo bien, 1 si encontró problemas (un ::error de GitHub por cada uno) y 2 si no
// pudo comparar. Tests: migration-order.test.ts (npm test de la raíz).
import { execFileSync } from "node:child_process";

export const MIGRATIONS_DIR = "supabase/migrations/";

// El formato de `supabase migration new`: AAAAMMDDHHMMSS_nombre.sql. El CLI (pkg/migration/file.go) aplica
// todo lo que calce con `^([0-9]+)_(.*)\.sql$` (cualquier cantidad de dígitos, nombre vacío incluido) y
// saltea el resto. Acá las migraciones que ya están en main se reconocen con el patrón del CLI
// (CLI_MIGRATION) y a las nuevas se les exigen además los 14 dígitos (MIGRATION_NAME), porque el CLI
// compara las versiones como texto.
const CLI_MIGRATION = /^(\d+)_.*\.sql$/;
const MIGRATION_NAME = /^(\d{14})_[^/]+\.sql$/;
const TITLE = "Orden de las migraciones";

export type MigrationProblem = { file: string; title: string; message: string };

export type MigrationTrees = {
  /** Rutas (desde la raíz del repo) en el main sobre el que se mezcla el PR. */
  base: readonly string[];
  /** Rutas en el resultado del merge. */
  merged: readonly string[];
  /** Migraciones que existen en los dos lados con contenido distinto. */
  modified: readonly string[];
};

/** Nombre del archivo si está directamente en supabase/migrations/ (sin subcarpetas). */
function topLevelName(path: string): string | null {
  if (!path.startsWith(MIGRATIONS_DIR)) return null;
  const name = path.slice(MIGRATIONS_DIR.length);
  return name !== "" && !name.includes("/") ? name : null;
}

function isSql(name: string): boolean {
  return name.toLowerCase().endsWith(".sql");
}

/** Versión de una migración bien nombrada (14 dígitos), o null. */
function versionOf(name: string): string | null {
  return MIGRATION_NAME.exec(name)?.[1] ?? null;
}

/** Versión con la que el CLI de Supabase guardaría la migración, o null si la saltea. */
function appliedVersionOf(name: string): string | null {
  return CLI_MIGRATION.exec(name)?.[1] ?? null;
}

/** Los problemas del PR; una lista vacía es que está todo bien. Función pura: los tests la llaman directo. */
export function checkMigrationOrder(trees: MigrationTrees): MigrationProblem[] {
  const sqlIn = (paths: readonly string[]) =>
    [...new Set(paths)].filter((path) => {
      const name = topLevelName(path);
      return name !== null && isSql(name);
    }).sort();
  const base = sqlIn(trees.base);
  const merged = sqlIn(trees.merged);
  const baseSet = new Set(base);
  const mergedSet = new Set(merged);
  const name = (path: string) => topLevelName(path) ?? path;
  const problems: MigrationProblem[] = [];

  // Las de main que producción ya aplicó (las que el CLI no saltea).
  const applied = base.filter((path) => appliedVersionOf(name(path)) !== null);
  const appliedVersion = (path: string) => appliedVersionOf(name(path)) ?? "";
  const newest = applied.reduce<string | null>((max, path) => (max === null || appliedVersion(path) > appliedVersion(max) ? path : max), null);
  const newestVersion = newest === null ? null : appliedVersion(newest);

  for (const path of applied) {
    if (!mergedSet.has(path)) {
      problems.push({
        file: path,
        title: "Migración de main borrada o renombrada",
        message: `El PR borra o renombra ${name(path)}, que ya está en main y producción ya aplicó: db push cortaría porque no encuentra esa versión en el repo. Dejala como está; si hay que cambiar algo, va en una migración nueva con una versión posterior.`,
      });
    }
  }
  const modified = new Set(trees.modified);
  for (const path of applied) {
    if (mergedSet.has(path) && modified.has(path)) {
      problems.push({
        file: path,
        title: "Migración de main cambiada",
        message: `El PR cambia ${name(path)}, que ya está en main: producción no vuelve a correr una migración aplicada, así que el cambio nunca llegaría. Volvé el archivo a como está en main y hacé el cambio en una migración nueva con una versión posterior (por ejemplo, reescribiendo la función con create or replace).`,
      });
    }
  }

  const added = merged.filter((path) => !baseSet.has(path));
  for (const path of added) {
    const version = versionOf(name(path));
    if (version === null) {
      const skipped = appliedVersionOf(name(path)) === null;
      const why = skipped
        ? "el CLI de Supabase saltea un .sql con ese nombre y nunca lo aplicaría"
        : "el CLI lo aplicaría, pero acá se exigen 14 dígitos porque las versiones se comparan como texto";
      problems.push({
        file: path,
        title: "Nombre de migración inválido",
        message: `${name(path)} no tiene la forma AAAAMMDDHHMMSS_nombre.sql (14 dígitos, «_», un nombre y .sql en minúsculas): ${why}. Creala con \`npx supabase migration new <nombre>\`.`,
      });
    } else if (newest !== null && newestVersion !== null && version <= newestVersion) {
      problems.push({
        file: path,
        title: "Migración fuera de orden",
        message: `${name(path)} (versión ${version}) no es posterior a la última de main, ${name(newest)}: db push corre sin --include-all y la rechazaría después del merge. Renombrala con una versión mayor que ${newestVersion} (y actualizá las referencias a su nombre).`,
      });
    }
  }

  // Supabase guarda una fila por versión: dos archivos con la misma no pueden convivir. Una nueva que ya
  // salió como fuera de orden no se repite acá (al renombrarla se arreglan las dos cosas).
  const reported = new Set(problems.map((problem) => problem.file));
  const byVersion = new Map<string, string[]>();
  for (const path of merged) {
    const version = versionOf(name(path));
    if (version !== null) byVersion.set(version, [...(byVersion.get(version) ?? []), path]);
  }
  for (const [version, paths] of byVersion) {
    const fresh = paths.filter((path) => !baseSet.has(path) && !reported.has(path));
    if (paths.length > 1 && fresh.length > 0) {
      problems.push({
        file: fresh[0],
        title: "Versión de migración repetida",
        message: `La versión ${version} está en más de una migración: ${paths.map(name).join(", ")}. Supabase guarda una sola por versión: dale a la nueva una versión libre posterior a la última de main.`,
      });
    }
  }
  return problems;
}

/** Escapa un valor para un comando de GitHub Actions (::error ...::mensaje). */
export function escapeAnnotation(value: string, property: boolean): string {
  const data = value.replaceAll("%", "%25").replaceAll("\r", "%0D").replaceAll("\n", "%0A");
  return property ? data.replaceAll(":", "%3A").replaceAll(",", "%2C") : data;
}

function annotate(problem: MigrationProblem | { file: null; title: string; message: string }): string {
  const props = [
    ...(problem.file === null ? [] : [`file=${escapeAnnotation(problem.file, true)}`]),
    `title=${escapeAnnotation(problem.title, true)}`,
  ];
  return `::error ${props.join(",")}::${escapeAnnotation(problem.message, false)}`;
}

// ---------------------------------------------------------------------------
// Lo que el CI corre: arma las listas con git
// ---------------------------------------------------------------------------

class UsageError extends Error {}

function git(cwd: string, args: readonly string[]): string {
  return execFileSync("git", ["-c", "core.quotepath=off", ...args], {
    cwd,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    maxBuffer: 64 * 1024 * 1024,
  });
}

function gitSucceeds(cwd: string, args: readonly string[]): boolean {
  try {
    git(cwd, args);
    return true;
  } catch {
    return false;
  }
}

function nulList(text: string): string[] {
  return text.split("\0").filter((entry) => entry !== "");
}

/**
 * Las listas de migraciones de main y del merge. Sin `baseRef`, como en el CI: HEAD es el merge commit del
 * PR y HEAD^1, main. Con `baseRef`, en local: simula el merge de HEAD sobre esa rama con git merge-tree.
 */
export function readTrees(cwd: string, baseRef?: string): MigrationTrees {
  let base: string;
  let merged: string;
  if (baseRef === undefined) {
    if (!gitSucceeds(cwd, ["rev-parse", "--verify", "--quiet", "HEAD^2"])) {
      throw new UsageError(
        "HEAD no es un merge commit (le falta el segundo padre), así que no se sabe contra qué main comparar. En el CI corre sobre el merge commit del PR (actions/checkout con fetch-depth: 2); en local, pasá la rama base: node .github/scripts/migration-order.ts origin/main",
      );
    }
    base = git(cwd, ["rev-parse", "--verify", "HEAD^1^{commit}"]).trim();
    merged = git(cwd, ["rev-parse", "--verify", "HEAD^{tree}"]).trim();
  } else {
    if (!gitSucceeds(cwd, ["rev-parse", "--verify", "--quiet", `${baseRef}^{commit}`])) {
      throw new UsageError(`No existe la rama o el commit «${baseRef}».`);
    }
    base = git(cwd, ["rev-parse", "--verify", `${baseRef}^{commit}`]).trim();
    try {
      merged = git(cwd, ["merge-tree", "--write-tree", base, "HEAD"]).split("\n")[0].trim();
    } catch (error) {
      // merge-tree sale con 1 cuando hay conflictos; cualquier otro código es otro problema (git viejo, historias sin relación).
      if ((error as { status?: number }).status === 1) {
        throw new UsageError(`HEAD no se mezcla sin conflictos sobre «${baseRef}»: resolvelos y volvé a probar.`);
      }
      const detail = String((error as { stderr?: unknown }).stderr ?? error).trim();
      throw new UsageError(`git merge-tree falló (hace falta git >= 2.38 e historias relacionadas): ${detail}`);
    }
  }
  const list = (treeish: string) => nulList(git(cwd, ["ls-tree", "-z", "--full-tree", "--name-only", treeish, "--", MIGRATIONS_DIR]));
  return {
    base: list(base),
    merged: list(merged),
    modified: nulList(git(cwd, ["diff", "-z", "--name-only", "--no-renames", "--diff-filter=M", base, merged, "--", MIGRATIONS_DIR])),
  };
}

export function main(args: readonly string[], cwd: string = process.cwd()): number {
  if (args.length > 1 || args.some((arg) => arg.startsWith("-"))) {
    console.log(annotate({ file: null, title: TITLE, message: "Uso: node .github/scripts/migration-order.ts [rama-base]" }));
    return 2;
  }
  let trees: MigrationTrees;
  try {
    const root = git(cwd, ["rev-parse", "--show-toplevel"]).trim();
    trees = readTrees(root, args[0]);
  } catch (error) {
    const message = error instanceof UsageError ? error.message : `No se pudo leer el repo con git: ${error instanceof Error ? error.message : String(error)}`;
    console.log(annotate({ file: null, title: TITLE, message }));
    return 2;
  }
  const problems = checkMigrationOrder(trees);
  for (const problem of problems) console.log(annotate(problem));
  if (problems.length > 0) {
    console.log(`${problems.length} problema(s) con las migraciones: ver los avisos de arriba.`);
    return 1;
  }
  const baseNames = new Set(trees.base);
  const added = trees.merged.filter((path) => !baseNames.has(path) && path.toLowerCase().endsWith(".sql"));
  const newest = trees.base.filter((path) => appliedVersionOf(topLevelName(path) ?? "") !== null).sort().at(-1);
  const count = added.length === 1 ? "1 nueva" : `${added.length} nuevas`;
  console.log(`Migraciones en orden: ${count}; la última de main es ${newest === undefined ? "(ninguna)" : topLevelName(newest)}.`);
  return 0;
}

if (import.meta.main) {
  process.exitCode = main(process.argv.slice(2));
}
