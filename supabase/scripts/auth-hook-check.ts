// Comprueba, ANTES del PATCH de Auth, que la función del hook de la cocina existe en producción con sus
// grants (docs/contracts/auth.md §8). El PATCH que prende el hook corre antes de db push: un hook prendido
// que apunta a una función que no está (o que alguien más puede ejecutar) rompe el login de todos. Se mira
// la base por la Management API, solo lectura (POST /v1/projects/{ref}/database/query/read-only), y si algo
// no está como debe, el despliegue corta antes de tocar Auth. Nunca imprime el token.
//
// También el freno de altas (public.before_user_created_guard, PR20): antes de prender las altas, la misma comprobación
// con su regla (signups_daily_cap).
//
// Uso (CI): SUPABASE_ACCESS_TOKEN=… SUPABASE_PROJECT_REF=… node supabase/scripts/auth-hook-check.ts [kitchen|signup]
// Solo sintaxis borrable: corre con node, sin compilar.
import { pathToFileURL } from "node:url";

/** Una función de hook de Auth (pg-functions): su firma y la regla que la reconoce (un texto de su cuerpo). */
export interface HookFunction {
  signature: string;
  rule: string;
  /** Cómo se la nombra en los mensajes. */
  label: string;
}

export const HOOK_FUNCTIONS = {
  kitchen: { signature: "public.kitchen_access_token_hook(jsonb)", rule: "kitchen_code_only", label: "El hook de la cocina" },
  signup: { signature: "public.before_user_created_guard(jsonb)", rule: "signups_daily_cap", label: "El freno de altas" },
} as const satisfies Record<string, HookFunction>;

/** Solo lee: una fila con la definición y quién puede ejecutar la función (ninguna fila = no existe). */
export function hookFunctionSql(hook: HookFunction): string {
  if (!/^public\.[a-z_]+\(jsonb\)$/.test(hook.signature) || !/^[a-z_]+$/.test(hook.rule)) throw new Error("hook inválido");
  return KITCHEN_HOOK_SQL.replace("'kitchen_code_only'", `'${hook.rule}'`).replace(
    "'public.kitchen_access_token_hook(jsonb)'",
    `'${hook.signature}'`,
  );
}

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
  return checkHookFunction(HOOK_FUNCTIONS.kitchen, token, projectRef, fetchFn, baseUrl);
}

/** Lo mismo para cualquier función de hook ([hook]). */
export async function checkHookFunction(
  hook: HookFunction,
  token: string,
  projectRef: string,
  fetchFn: typeof fetch = fetch,
  baseUrl = "https://api.supabase.com",
): Promise<KitchenHookResult> {
  try {
    const response = await fetchFn(`${baseUrl}/v1/projects/${projectRef}/database/query/read-only`, {
      method: "POST",
      headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
      body: JSON.stringify({ query: hookFunctionSql(hook) }),
    });
    // La Management API responde 201 a esta consulta. Nunca se devuelve el cuerpo crudo de un error.
    if (response.status !== 200 && response.status !== 201) {
      return { kind: "error", message: `la Management API respondió ${response.status} a la consulta de la función` };
    }
    const rows: unknown = await response.json().catch(() => null);
    if (!Array.isArray(rows)) return { kind: "error", message: "la Management API no devolvió una lista de filas" };
    if (rows.length === 0) {
      return { kind: "bad", problems: [`${hook.signature} no existe en la base de producción (falta aplicar la migración)`] };
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
    if (row.has_rule !== true) problems.push(`la función no trae la regla ${hook.rule} (no es la del repo)`);
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
  const which = process.argv[2] ?? "kitchen";
  if (which !== "kitchen" && which !== "signup") fail("Uso: node supabase/scripts/auth-hook-check.ts [kitchen|signup]");
  const hook = HOOK_FUNCTIONS[which as keyof typeof HOOK_FUNCTIONS];
  if (!token) fail(`Falta SUPABASE_ACCESS_TOKEN: no se puede comprobar ${hook.label.toLowerCase()}`);
  if (!/^[a-z]{20}$/.test(ref)) fail("SUPABASE_PROJECT_REF no es una referencia de proyecto válida");
  const result = await checkHookFunction(hook, token, ref, fetch, override || undefined);
  if (result.kind === "ok") {
    process.stdout.write(`${hook.label}: ${hook.signature} existe, es security definer y solo la ejecuta supabase_auth_admin.\n`);
  } else if (result.kind === "bad") {
    fail(`${hook.label} no se puede prender: ${result.problems.join("; ")}. Auth no se tocó (docs/contracts/auth.md §8).`);
  } else {
    fail(`No se pudo comprobar ${hook.label.toLowerCase()}: ${result.message}. Auth no se tocó.`);
  }
}
