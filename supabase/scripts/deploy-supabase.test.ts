// Tests de lo que deploy-supabase.yml hace con la base de producción. Correr con: npm test.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";

const repo = (path: string): URL => new URL(`../../${path}`, import.meta.url);
const WORKFLOW = readFileSync(repo(".github/workflows/deploy-supabase.yml"), "utf8");

/** El bloque de un paso del workflow: desde su "- name:" hasta el paso siguiente. */
function step(name: string): string {
  const start = WORKFLOW.indexOf(`- name: ${name}`);
  assert.notEqual(start, -1, `no está el paso "${name}"`);
  const next = WORKFLOW.indexOf("\n      - ", start + 1);
  return WORKFLOW.slice(start, next === -1 ? undefined : next);
}

test("migraciones: versión de 14 cifras y ninguna repetida (el CLI la usa como clave)", () => {
  // db start, db reset y db push guardan cada migración en supabase_migrations.schema_migrations con
  // el prefijo numérico como clave primaria. Dos con la misma versión (por ejemplo, de dos ramas que
  // llegan a main) rompen db start en CI, y db push en producción da una por aplicada sin correrla.
  const files = readdirSync(repo("supabase/migrations")).sort();
  const malformed = files.filter((name) => !/^\d{14}_[a-z0-9_]+\.sql$/.test(name));
  assert.deepEqual(malformed, [], "nombre esperado: AAAAMMDDHHMMSS_nombre.sql");

  const byVersion = new Map<string, string>();
  const repeated: string[] = [];
  for (const name of files) {
    const version = name.slice(0, 14);
    const other = byVersion.get(version);
    if (other) repeated.push(`${other} y ${name}`);
    else byVersion.set(version, name);
  }
  assert.deepEqual(repeated, [], "cambiarle la versión a una de las dos (una libre, posterior a la última)");
});

test("función chef: se despliega después de las migraciones y de los secretos, con verify_jwt = true", () => {
  // chef llama a las funciones chef_* de la migración de reservas (db push tiene que correr antes) y
  // usa ALLOWED_ORIGINS, que carga el paso de los secretos (contrato chef-api.md §9).
  const migrations = WORKFLOW.indexOf("- name: Migraciones (db push)");
  const secrets = WORKFLOW.indexOf("- name: Secretos de la función");
  const chef = WORKFLOW.indexOf("- name: Desplegar chef");
  assert.ok(migrations !== -1 && secrets !== -1, "están los pasos de las migraciones y de los secretos");
  assert.ok(chef > migrations && chef > secrets, "chef se despliega después de db push y de los secretos");

  const run = step("Desplegar chef");
  assert.match(run, /if: env\.HAS_SUPABASE == 'true'/);
  assert.match(run, /supabase functions deploy chef --project-ref "\$\{SUPABASE_PROJECT_REF\}" --use-api/);
  assert.ok(!run.includes("--no-verify-jwt"), "el chequeo de JWT de la plataforma queda prendido");

  // verify_jwt sale de config.toml: con JWT para chef (la llama la app con la sesión de Evelyn), sin
  // JWT para public-request (la llama gente sin cuenta).
  const config = readFileSync(repo("supabase/config.toml"), "utf8");
  const section = (name: string): string => new RegExp(`\\[functions\\.${name}\\]\\n([\\s\\S]*?)(?:\\n\\[|$)`).exec(config)?.[1] ?? "";
  assert.match(section("chef"), /^enabled = true$/m);
  assert.match(section("chef"), /^verify_jwt = true$/m);
  assert.match(section("public-request"), /^verify_jwt = false$/m);
});

const ACCOUNTS_STEP = "Cuentas de la cocinera y sus colaboradores";

test("cuenta de la cocinera: recibe el horario inicial justo después de promote_to_chef", () => {
  // db push corre antes de que exista la cocinera: en un proyecto nuevo la migración
  // 20261115130100_default_availability.sql no encuentra a nadie y, sin reglas, el calendario de la
  // web no marca ningún día (contrato §11.1). El paso solo llega ahí la primera vez.
  const migrations = WORKFLOW.indexOf("- name: Migraciones (db push)");
  const chefStep = WORKFLOW.indexOf(`- name: ${ACCOUNTS_STEP}`);
  assert.ok(migrations !== -1 && migrations < chefStep, "db push corre antes de crear la cuenta");

  const run = step(ACCOUNTS_STEP);
  const promote = run.indexOf("public.promote_to_chef(");
  const schedule = run.indexOf('sql "select private.add_default_availability()');
  assert.notEqual(promote, -1, "el paso llama a promote_to_chef");
  assert.ok(schedule > promote, "después de promote_to_chef, private.add_default_availability()");
});

test("colaboradores: CHEF_MEMBER_EMAILS es un secreto y cada email se enmascara antes de usarlo", () => {
  // Los valores de las variables (vars.*) salen en claro en el log de cada paso que las usa (el
  // bloque env); los secretos salen como ***. Un email suelto dentro de la lista no lo enmascara
  // GitHub: se registra cada uno con ::add-mask:: antes de hacer nada con él.
  const run = step(ACCOUNTS_STEP);
  assert.match(run, /^\s+CHEF_MEMBER_EMAILS: \$\{\{ secrets\.CHEF_MEMBER_EMAILS \}\}$/m);
  assert.ok(!WORKFLOW.includes("vars.CHEF_MEMBER_EMAILS"), "nunca como variable");

  const mask = run.indexOf('echo "::add-mask::${email}"');
  assert.notEqual(mask, -1, "enmascara cada email");
  assert.ok(mask < run.indexOf('users_with "${email}"'), "antes de consultar la base con él");
  assert.ok(mask < run.indexOf('create_user "${email}"'), "y antes de crear su cuenta");

  // Ningún echo ni mensaje lleva un email: solo la versión enmascarada (masked) o un contador.
  const leaks = run
    .split("\n")
    .filter((line) => /\becho\b/.test(line) && /\$\{(email|CHEF_MEMBER_EMAILS)\}|\$CHEF_MEMBER_EMAILS\b/.test(line))
    .filter((line) => !line.includes("::add-mask::${email}"));
  assert.deepEqual(leaks, [], "líneas que imprimirían un email");
  assert.ok(!run.includes("${CHEF_MEMBER_EMAILS}"), "la lista la lee solo el script (del entorno)");
});

test("colaboradores: en cada despliegue, también con la cocinera ya creada; cuentas confirmadas y la lista en la base", () => {
  const run = step(ACCOUNTS_STEP);
  // Antes el paso terminaba con exit 0 si ya había cocinera: lo de los colaboradores no corría nunca.
  assert.ok(!/\bexit 0\b/.test(run), "sin salidas anticipadas: los colaboradores corren en cada despliegue");

  const list = run.indexOf("node supabase/scripts/chef-members.ts list");
  const sync = run.indexOf('sql "$(node supabase/scripts/chef-members.ts sql)"');
  assert.notEqual(list, -1, "la lista la valida supabase/scripts/chef-members.ts (con tests)");
  assert.ok(sync > list, "y la aplica private.sync_chef_members, con el SQL que arma el mismo script");
  assert.ok(run.indexOf('create_user "${email}"') > list && run.indexOf('create_user "${email}"') < sync,
    "las cuentas que faltan se crean antes de sincronizar (la base exige que existan)");

  // Una sola manera de crear cuentas: confirmada, con una contraseña al azar que nadie conoce.
  const create = /create_user\(\) \{[\s\S]*?\n {10}\}/.exec(run)?.[0] ?? "";
  assert.match(create, /email_confirm: true/);
  assert.match(create, /openssl rand -hex 32/);
  assert.match(run, /create_user "\$\{CHEF_LOGIN_EMAIL\}"/, "la de la cocinera también");

  // Una cuenta que ya existe sin confirmar la registró otro: corta, como con la de la cocinera.
  assert.match(run, /unconfirmed_with "\$\{email\}"/);
});

test("usuarios en Auth: el aviso cuenta a la cocinera y a sus colaboradores", () => {
  const run = step(ACCOUNTS_STEP);
  assert.ok(!run.includes("(tiene que ser 1)"), "ya no espera un solo usuario");
  assert.match(run, /select count\(\*\)::int as n from public\.chef_members/);
  assert.match(run, /expected=\$\(\(chefs \+ members_db\)\)/);
  assert.match(run, /::warning::Hay \$\{total\} usuarios en Auth y se esperaban \$\{expected\}/);
});

test("el encabezado del workflow documenta CHEF_MEMBER_EMAILS entre los secretos", () => {
  const header = WORKFLOW.slice(0, WORKFLOW.indexOf("\nname: "));
  assert.match(header, /CHEF_MEMBER_EMAILS/);
  assert.match(header, /secreto/i);
});
