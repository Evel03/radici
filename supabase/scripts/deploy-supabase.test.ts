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

const CHEF_STEP = "Cuenta de la cocinera (solo la primera vez)";
const MEMBERS_STEP = "Colaboradores de la cocinera";
/** El script de los dos pasos de cuentas (se corre de verdad en deploy-accounts.test.ts). */
const ACCOUNTS_SCRIPT = readFileSync(repo("supabase/scripts/deploy-accounts.sh"), "utf8");

/** Una función de deploy-accounts.sh: desde "nombre() {" hasta la llave que la cierra. */
function scriptFunction(name: string): string {
  const body = new RegExp(`\\n${name}\\(\\) \\{\\n[\\s\\S]*?\\n\\}\\n`).exec(ACCOUNTS_SCRIPT)?.[0];
  assert.ok(body, `no está la función ${name} en deploy-accounts.sh`);
  return body;
}

test("cuenta de la cocinera: después de db push y antes de los secretos; recibe el horario justo después de promote_to_chef", () => {
  // db push corre antes de que exista la cocinera: en un proyecto nuevo la migración
  // 20261115130100_default_availability.sql no encuentra a nadie y, sin reglas, el calendario de la
  // web no marca ningún día (contrato §11.1). El paso solo llega ahí la primera vez.
  const migrations = WORKFLOW.indexOf("- name: Migraciones (db push)");
  const chefStep = WORKFLOW.indexOf(`- name: ${CHEF_STEP}`);
  const secrets = WORKFLOW.indexOf("- name: Secretos de la función");
  assert.ok(migrations !== -1 && migrations < chefStep && chefStep < secrets, "db push → cuenta de la cocinera → secretos");
  const run = step(CHEF_STEP);
  assert.match(run, /if: env\.HAS_SUPABASE == 'true'/);
  assert.match(run, /run: bash supabase\/scripts\/deploy-accounts\.sh chef$/m);
  assert.ok(!run.includes("CHEF_MEMBER_EMAILS"), "los colaboradores van en su propio paso");

  const chef = scriptFunction("chef_account");
  const promote = chef.indexOf("public.promote_to_chef(");
  const schedule = chef.indexOf('count "select private.add_default_availability() as n"');
  assert.notEqual(promote, -1, "la cocinera pasa por promote_to_chef");
  assert.ok(schedule > promote, "después de promote_to_chef, private.add_default_availability()");
  assert.match(chef, /Ya hay cocinera: no se toca[\s\S]*?return 0/, "con una cocinera ya creada no hace nada");
});

test("colaboradores: su propio paso, al final, aunque haya fallado otro, siempre que db push haya salido bien", () => {
  // Antes iban en el paso de la cocinera, entre db push y el despliegue de las funciones: un email mal
  // escrito en el secreto dejaba la base migrada con las funciones viejas. Al final, un error solo deja
  // el despliegue en rojo. Y una baja de la lista no espera a que se arregle otro paso.
  const chefDeploy = WORKFLOW.indexOf("- name: Desplegar chef");
  const members = WORKFLOW.indexOf(`- name: ${MEMBERS_STEP}`);
  assert.ok(chefDeploy !== -1 && members > chefDeploy, "después de desplegar las funciones");
  assert.match(step("Migraciones (db push)"), /^\s+id: db_push$/m);
  const run = step(MEMBERS_STEP);
  assert.match(run, /^\s+if: \$\{\{ !cancelled\(\) && env\.HAS_SUPABASE == 'true' && steps\.db_push\.outcome == 'success' \}\}$/m);
  assert.match(run, /run: bash supabase\/scripts\/deploy-accounts\.sh members$/m);
});

test("colaboradores: CHEF_MEMBER_EMAILS es un secreto y cada email se enmascara antes de usarlo", () => {
  // Los valores de las variables (vars.*) salen en claro en el log de cada paso que las usa (el
  // bloque env); los secretos salen como ***. Un email suelto dentro de la lista no lo enmascara
  // GitHub: se registra cada uno con ::add-mask:: antes de hacer nada con él.
  assert.match(step(MEMBERS_STEP), /^\s+CHEF_MEMBER_EMAILS: \$\{\{ secrets\.CHEF_MEMBER_EMAILS \}\}$/m);
  assert.ok(!WORKFLOW.includes("vars.CHEF_MEMBER_EMAILS"), "nunca como variable");

  const members = scriptFunction("members");
  const mask = members.indexOf('echo "::add-mask::${email}"');
  assert.notEqual(mask, -1, "enmascara cada email");
  assert.ok(mask < members.indexOf('users_with "${email}"'), "antes de consultar la base con él");
  assert.ok(mask < members.indexOf('create_user "${email}"'), "y antes de crear su cuenta");

  // Ningún echo ni mensaje lleva un email de colaborador: solo la versión enmascarada o un contador.
  const leaks = members
    .split("\n")
    .filter((line) => /\becho\b/.test(line) && /\$\{(email|CHEF_MEMBER_EMAILS)\}|\$CHEF_MEMBER_EMAILS\b/.test(line))
    .filter((line) => !line.includes("::add-mask::${email}"));
  assert.deepEqual(leaks, [], "líneas que imprimirían un email");
  assert.ok(!ACCOUNTS_SCRIPT.includes("${CHEF_MEMBER_EMAILS}"), "la lista la lee solo chef-members.ts (del entorno)");
});

test("cuentas: una sola manera de crearlas, confirmadas y con una contraseña al azar", () => {
  const create = scriptFunction("create_user");
  assert.match(create, /email_confirm: true/);
  assert.match(create, /openssl rand -hex 32/);
  assert.match(scriptFunction("chef_account"), /create_user "\$\{CHEF_LOGIN_EMAIL\}"/, "la de la cocinera");
  assert.match(scriptFunction("members"), /create_user "\$\{email\}"/, "y las de los colaboradores");
});

test("el encabezado del workflow documenta CHEF_MEMBER_EMAILS entre los secretos, con la privacy y cómo aplicarlo", () => {
  const header = WORKFLOW.slice(0, WORKFLOW.indexOf("\nname: "));
  assert.match(header, /CHEF_MEMBER_EMAILS/);
  assert.match(header, /secreto/i);
  assert.match(header, /SPEC §6/, "quién puede ser colaborador sin cambiar la privacy");
  assert.match(header, /Run\s+#?\s*workflow/, "cambiar el secreto no hace nada hasta correr el workflow");
});

test("traducción: ANTHROPIC_API_KEY es un secreto opcional que carga el paso de los secretos, y avisa si falta", () => {
  // La función chef la usa para traducir los platos (contrato chef-api.md §12); sin ella responde 503.
  const run = step("Secretos de la función");
  assert.match(run, /^\s+ANTHROPIC_API_KEY: \$\{\{ secrets\.ANTHROPIC_API_KEY \}\}$/m);
  assert.ok(!WORKFLOW.includes("vars.ANTHROPIC_API_KEY"), "nunca como variable: saldría en claro en el log");
  // Va en los pares que se cargan con supabase secrets set, sin pasar por echo.
  const loop = /for name in ([\s\S]*?); do\n\s+value="\$\{!name:-\}"/.exec(run)?.[1] ?? "";
  assert.match(loop, /\bANTHROPIC_API_KEY\b/, "se carga con los demás secretos");
  // Opcional: no está entre las que hacen fallar el despliegue ni entre las que avisan como obligatorias.
  const required = /for name in (TURNSTILE_SECRET_KEY IP_HASH_SALT[^;]*); do\n\s+grep -qx/.exec(run)?.[1] ?? "";
  assert.ok(required !== "" && !required.includes("ANTHROPIC_API_KEY"), "no corta el despliegue");
  assert.match(run, /if \[ -z "\$\{ANTHROPIC_API_KEY:-\}" \] && ! grep -qx "ANTHROPIC_API_KEY" <<< "\$\{names\}"; then\n\s+echo "::warning::Sin ANTHROPIC_API_KEY la traducción automática de los platos queda apagada/);
  assert.doesNotMatch(run, /echo[^\n]*\$\{?ANTHROPIC_API_KEY\b/, "ningún echo imprime el valor");

  // TRANSLATE_TRANSPORT=fake es de desarrollo: el workflow no lo carga y avisa si está en Supabase.
  assert.ok(!/TRANSLATE_TRANSPORT: \$\{\{/.test(WORKFLOW), "no se carga desde GitHub");
  assert.match(run, /grep -qx "TRANSLATE_TRANSPORT" <<< "\$\{names\}"/);

  const header = WORKFLOW.slice(0, WORKFLOW.indexOf("\nname: "));
  assert.match(header, /opcionales: [^)]*ANTHROPIC_API_KEY/);
  assert.match(header, /solo[\s#]+van el nombre y la descripción del plato/, "qué se manda a Anthropic");
});
