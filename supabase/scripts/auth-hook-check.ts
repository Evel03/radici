// Comprueba, ANTES del PATCH de Auth, que la función del hook de la cocina existe en producción con sus
// grants (docs/contracts/auth.md §8). El PATCH que prende el hook corre antes de db push: un hook prendido
// que apunta a una función que no está (o que alguien más puede ejecutar) rompe el login de todos. Se mira
// la base por la Management API, solo lectura (POST /v1/projects/{ref}/database/query/read-only), y si algo
// no está como debe, el despliegue corta antes de tocar Auth. Nunca imprime el token.
//
// Uso (CI): SUPABASE_ACCESS_TOKEN=… SUPABASE_PROJECT_REF=… node supabase/scripts/auth-hook-check.ts
// Solo sintaxis borrable: corre con node, sin compilar.
import { pathToFileURL } from "node:url";

/** Solo lee: una fila con la definición y quién puede ejecutar la función (ninguna fila = no existe). */
export const KITCHEN_HOOK_SQL = `select
  p.prosecdef as security_definer,
  has_function_privilege('supabase_auth_admin', p.oid, 'EXECUTE') as auth_admin,
  has_function_privilege('anon', p.oid, 'EXECUTE') as anon,
  has_function_privilege('authenticated', p.oid, 'EXECUTE') as authenticated,
  has_function_privilege('service_role', p.oid, 'EXECUTE') as service_role,
  exists (
    select 1 from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
    where a.grantee = 0 and a.privilege_type = 'EXECUTE'
  ) as public_exec,
  position('kitchen_code_only' in p.prosrc) > 0 as has_rule
from pg_proc p
where p.oid = to_regprocedure('public.kitchen_access_token_hook(jsonb)')`;

export type KitchenHookResult =
  | { kind: "ok" }
  | { kind: "bad"; problems: string[] }
  | { kind: "error"; message: string };

const FLAGS = ["security_definer", "auth_admin", "anon", "authenticated", "service_role", "public_exec", "has_rule"] as const;

/** Consulta la base de producción y dice si la función del hook está como tiene que estar. [fetchFn] y [baseUrl] solo cambian en los tests. */
export async function checkKitchenHook(
  token: string,
  projectRef: string,
  fetchFn: typeof fetch = fetch,
  baseUrl = "https://api.supabase.com",
): Promise<KitchenHookResult> {
  try {
    const response = await fetchFn(`${baseUrl}/v1/projects/${projectRef}/database/query/read-only`, {
      method: "POST",
      headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
      body: JSON.stringify({ query: KITCHEN_HOOK_SQL }),
    });
    // La Management API responde 201 a esta consulta. Nunca se devuelve el cuerpo crudo de un error.
    if (response.status !== 200 && response.status !== 201) {
      return { kind: "error", message: `la Management API respondió ${response.status} a la consulta de la función` };
    }
    const rows: unknown = await response.json().catch(() => null);
    if (!Array.isArray(rows)) return { kind: "error", message: "la Management API no devolvió una lista de filas" };
    if (rows.length === 0) {
      return { kind: "bad", problems: ["public.kitchen_access_token_hook(jsonb) no existe en la base de producción (falta aplicar la migración)"] };
    }
    if (rows.length !== 1) return { kind: "error", message: "la consulta de la función devolvió más de una fila" };
    const row = rows[0] as Record<string, unknown>;
    // Sin cada campo, y booleano de verdad, no se sabe: no pasa en silencio.
    for (const flag of FLAGS) {
      if (typeof row[flag] !== "boolean") return { kind: "error", message: `la consulta de la función no informó ${flag}` };
    }
    const problems: string[] = [];
    if (row.security_definer !== true) problems.push("la función no es security definer (supabase_auth_admin no puede leer las tablas cerradas)");
    if (row.auth_admin !== true) problems.push("supabase_auth_admin no puede ejecutar la función");
    if (row.anon === true) problems.push("anon puede ejecutar la función");
    if (row.authenticated === true) problems.push("authenticated puede ejecutar la función");
    if (row.service_role === true) problems.push("service_role puede ejecutar la función");
    if (row.public_exec === true) problems.push("PUBLIC puede ejecutar la función");
    if (row.has_rule !== true) problems.push("la función no trae la regla kitchen_code_only (no es la del repo)");
    return problems.length > 0 ? { kind: "bad", problems } : { kind: "ok" };
  } catch {
    // Nunca el mensaje crudo: podría traer la URL o la cabecera.
    return { kind: "error", message: "no se pudo hablar con la Management API" };
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const token = process.env.SUPABASE_ACCESS_TOKEN ?? "";
  const ref = process.env.SUPABASE_PROJECT_REF ?? "";
  const override = process.env.SUPABASE_API_URL ?? "";
  const fail = (message: string): never => {
    process.stderr.write(`::error::${message}\n`);
    process.exit(2);
  };
  // El token nunca va a otro host: solo un servidor local (los tests) puede reemplazar la URL.
  if (override && !/^http:\/\/127\.0\.0\.1:\d+$/.test(override)) fail("SUPABASE_API_URL solo puede apuntar a 127.0.0.1 (tests)");
  if (!token) fail("Falta SUPABASE_ACCESS_TOKEN: no se puede comprobar el hook de la cocina");
  if (!/^[a-z]{20}$/.test(ref)) fail("SUPABASE_PROJECT_REF no es una referencia de proyecto válida");
  const result = await checkKitchenHook(token, ref, fetch, override || undefined);
  if (result.kind === "ok") {
    process.stdout.write("Hook de la cocina: public.kitchen_access_token_hook existe, es security definer y solo la ejecuta supabase_auth_admin.\n");
  } else if (result.kind === "bad") {
    fail(`El hook de la cocina no se puede prender: ${result.problems.join("; ")}. Auth no se tocó (docs/contracts/auth.md §8).`);
  } else {
    fail(`No se pudo comprobar el hook de la cocina: ${result.message}. Auth no se tocó.`);
  }
}
