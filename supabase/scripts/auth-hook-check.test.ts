// Tests de la comprobación previa al PATCH de Auth (auth-hook-check.ts): el hook de la cocina solo se
// prende si la función existe en producción con sus grants. Con una API falsa, sin red.
import { test } from "node:test";
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { createServer } from "node:http";
import { fileURLToPath } from "node:url";
import { checkKitchenHook, KITCHEN_HOOK_SQL } from "./auth-hook-check.ts";

const SCRIPT = fileURLToPath(new URL("./auth-hook-check.ts", import.meta.url));

const GOOD = { security_definer: true, auth_admin: true, anon: false, authenticated: false, service_role: false, public_exec: false, has_rule: true };

/** fetch falso de POST /v1/projects/{ref}/database/query/read-only: devuelve las filas que se le dan. */
function fakeApi(rows: unknown, options: { status?: number; seen?: { url: string; body: Record<string, unknown> }[] } = {}): typeof fetch {
  return (async (input: RequestInfo | URL, init?: RequestInit) => {
    assert.equal(init?.method, "POST");
    assert.match(String((init?.headers as Record<string, string>).Authorization), /^Bearer sbp_/);
    options.seen?.push({ url: String(input), body: JSON.parse(String(init?.body)) as Record<string, unknown> });
    return new Response(JSON.stringify(rows), { status: options.status ?? 201 });
  }) as typeof fetch;
}

const check = (rows: unknown, options: Parameters<typeof fakeApi>[1] = {}) =>
  checkKitchenHook("sbp_secreto", "abcdefghijklmnopqrst", fakeApi(rows, options));

test("la función existe, es security definer y solo supabase_auth_admin la ejecuta: pasa", async () => {
  assert.deepEqual(await check([GOOD]), { kind: "ok" });
});

test("pide solo lectura, a la ruta read-only de la base del proyecto, con la consulta fija", async () => {
  const seen: { url: string; body: Record<string, unknown> }[] = [];
  await check([GOOD], { seen });
  assert.equal(seen.length, 1);
  assert.equal(seen[0]?.url, "https://api.supabase.com/v1/projects/abcdefghijklmnopqrst/database/query/read-only");
  assert.equal(seen[0]?.body.query, KITCHEN_HOOK_SQL);
  assert.match(KITCHEN_HOOK_SQL, /kitchen_access_token_hook\(jsonb\)/);
  assert.doesNotMatch(KITCHEN_HOOK_SQL, /\b(insert|update|delete|drop|alter|create|grant|revoke)\b/i, "solo lee");
});

test("sin la función (ninguna fila): corta y lo dice", async () => {
  const result = await check([]);
  assert.equal(result.kind, "bad");
  assert.match(result.kind === "bad" ? result.problems.join(" ") : "", /no existe/);
});

test("grants o definición equivocados: corta y nombra cada problema", async () => {
  const cases: Array<[Record<string, unknown>, RegExp]> = [
    [{ auth_admin: false }, /supabase_auth_admin/],
    [{ anon: true }, /anon/],
    [{ authenticated: true }, /authenticated/],
    [{ service_role: true }, /service_role/],
    [{ public_exec: true }, /PUBLIC/],
    [{ security_definer: false }, /security definer/],
    [{ has_rule: false }, /kitchen_code_only/],
  ];
  for (const [change, pattern] of cases) {
    const result = await check([{ ...GOOD, ...change }]);
    assert.equal(result.kind, "bad", JSON.stringify(change));
    assert.match(result.kind === "bad" ? result.problems.join(" ") : "", pattern);
  }
});

test("una respuesta rara (campos que faltan, dos filas, no es una lista) no se da por buena", async () => {
  for (const rows of [[{ security_definer: true }], [GOOD, GOOD], { message: "x" }, "ok", [{ ...GOOD, anon: "false" }]]) {
    const result = await check(rows);
    assert.notEqual(result.kind, "ok", JSON.stringify(rows));
  }
});

test("error de la API: corta, sin la clave ni el cuerpo crudo", async () => {
  for (const status of [401, 403, 429, 500]) {
    const result = await check({ message: "sbp_secreto explotó" }, { status });
    assert.equal(result.kind, "error");
    assert.ok(!JSON.stringify(result).includes("sbp_secreto"));
    assert.match(result.kind === "error" ? result.message : "", new RegExp(String(status)));
  }
  const down = await checkKitchenHook("sbp_secreto", "abcdefghijklmnopqrst", (async () => {
    throw new Error("connect ECONNREFUSED con sbp_secreto");
  }) as typeof fetch);
  assert.equal(down.kind, "error");
  assert.ok(!JSON.stringify(down).includes("sbp_secreto"));
});

test("línea de comandos: sale con 0 si está bien y con 2, sin imprimir la clave, si falta la función", async () => {
  for (const [rows, code] of [[[GOOD], 0], [[], 2], [[{ ...GOOD, anon: true }], 2]] as const) {
    const server = createServer((request, response) => {
      assert.equal(request.url, "/v1/projects/abcdefghijklmnopqrst/database/query/read-only");
      response.writeHead(201, { "content-type": "application/json" }).end(JSON.stringify(rows));
    });
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
    const port = (server.address() as { port: number }).port;
    const outcome = await new Promise<{ code: number | null; text: string }>((resolve) => {
      execFile(process.execPath, [SCRIPT], {
        env: { ...process.env, SUPABASE_ACCESS_TOKEN: "sbp_secreto", SUPABASE_PROJECT_REF: "abcdefghijklmnopqrst", SUPABASE_API_URL: `http://127.0.0.1:${port}` },
      }, (error, stdout, stderr) => resolve({ code: error ? ((error as { code?: number }).code ?? 1) : 0, text: stdout + stderr }));
    });
    server.close();
    assert.equal(outcome.code, code, JSON.stringify(rows));
    assert.ok(!outcome.text.includes("sbp_secreto"));
  }
});

test("línea de comandos: sin token o sin proyecto, o con una URL que no es local, sale con 2", async () => {
  const run = (env: Record<string, string>) => new Promise<number | null>((resolve) => {
    execFile(process.execPath, [SCRIPT], { env: { ...process.env, SUPABASE_ACCESS_TOKEN: "", SUPABASE_PROJECT_REF: "", SUPABASE_API_URL: "", ...env } },
      (error) => resolve(error ? ((error as { code?: number }).code ?? 1) : 0));
  });
  assert.equal(await run({ SUPABASE_PROJECT_REF: "abcdefghijklmnopqrst" }), 2);
  assert.equal(await run({ SUPABASE_ACCESS_TOKEN: "sbp_x" }), 2);
  assert.equal(await run({ SUPABASE_ACCESS_TOKEN: "sbp_x", SUPABASE_PROJECT_REF: "abcdefghijklmnopqrst", SUPABASE_API_URL: "https://malo.example" }), 2);
  assert.equal(await run({ SUPABASE_ACCESS_TOKEN: "sbp_x", SUPABASE_PROJECT_REF: "../etc" }), 2);
});

test("el freno de altas (PR20): la misma consulta, con su función y su regla, y la regla está en la migración", async () => {
  const { HOOK_FUNCTIONS, hookFunctionSql, checkHookFunction } = await import("./auth-hook-check.ts");
  const sql = hookFunctionSql(HOOK_FUNCTIONS.signup);
  assert.match(sql, /to_regprocedure\('public\.before_user_created_guard\(jsonb\)'\)/);
  assert.match(sql, /position\('signups_daily_cap' in p\.prosrc\)/);
  assert.ok(!sql.includes("kitchen"), "nada de la función de la cocina");
  const migration = (await import("node:fs")).readFileSync(new URL("../migrations/20261126100000_auth_hooks.sql", import.meta.url), "utf8");
  assert.ok(migration.includes("'signups_daily_cap'"), "la regla con la que se la reconoce está en la función del repo");

  const row = { security_definer: true, auth_admin: true, anon: false, authenticated: false, service_role: false, public_exec: false, has_rule: true };
  const answer = (rows: unknown[]) => (async () => new Response(JSON.stringify(rows), { status: 201 })) as typeof fetch;
  assert.deepEqual(await checkHookFunction(HOOK_FUNCTIONS.signup, "t", "abcdefghijklmnopqrst", answer([row])), { kind: "ok" });
  const missing = await checkHookFunction(HOOK_FUNCTIONS.signup, "t", "abcdefghijklmnopqrst", answer([]));
  assert.deepEqual(missing, { kind: "bad", problems: ["public.before_user_created_guard(jsonb) no existe en la base de producción (falta aplicar la migración)"] });
  const noRule = await checkHookFunction(HOOK_FUNCTIONS.signup, "t", "abcdefghijklmnopqrst", answer([{ ...row, has_rule: false }]));
  assert.deepEqual(noRule, { kind: "bad", problems: ["la función no trae la regla signups_daily_cap (no es la del repo)"] });
});
