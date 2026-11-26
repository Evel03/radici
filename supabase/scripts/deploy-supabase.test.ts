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

test("función client-link: se despliega después de las migraciones y de los secretos, sin JWT (la clienta no tiene cuenta)", () => {
  // client-link llama a las funciones client_link_* (migración 20261121100000_menu_sends.sql) y usa
  // IP_HASH_SALT, ALLOWED_ORIGINS y los secretos de los avisos, que carga el paso de los secretos
  // (contrato client-link.md §8).
  const migrations = WORKFLOW.indexOf("- name: Migraciones (db push)");
  const secrets = WORKFLOW.indexOf("- name: Secretos de la función");
  const clientLink = WORKFLOW.indexOf("- name: Desplegar client-link");
  assert.notEqual(clientLink, -1, "está el paso de client-link");
  assert.ok(clientLink > migrations && clientLink > secrets, "client-link se despliega después de db push y de los secretos");

  const run = step("Desplegar client-link");
  assert.match(run, /if: env\.HAS_SUPABASE == 'true'/);
  assert.match(run, /supabase functions deploy client-link --project-ref "\$\{SUPABASE_PROJECT_REF\}" --use-api/);
  // verify_jwt sale de config.toml, no de una bandera en el comando.
  assert.ok(!run.includes("--no-verify-jwt"));
  const config = readFileSync(repo("supabase/config.toml"), "utf8");
  const section = /\[functions\.client-link\]\n([\s\S]*?)(?:\n\[|$)/.exec(config)?.[1] ?? "";
  assert.match(section, /^enabled = true$/m);
  assert.match(section, /^verify_jwt = false$/m);
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
  // La función chef la usa para traducir los platos (contrato chef-api.md §12); sin ella responde 501.
  const run = step("Secretos de la función");
  assert.match(run, /^\s+ANTHROPIC_API_KEY: \$\{\{ secrets\.ANTHROPIC_API_KEY \}\}$/m);
  assert.ok(!WORKFLOW.includes("vars.ANTHROPIC_API_KEY"), "nunca como variable: saldría en claro en el log");
  // Va en los pares que se cargan con supabase secrets set, sin pasar por echo.
  const loop = /for name in ([\s\S]*?); do\n\s+value="\$\{!name:-\}"/.exec(run)?.[1] ?? "";
  assert.match(loop, /\bANTHROPIC_API_KEY\b/, "se carga con los demás secretos");
  // Opcional: no está entre las que hacen fallar el despliegue ni entre las que avisan como obligatorias.
  const required = /for name in (TURNSTILE_SECRET_KEY IP_HASH_SALT[^;]*); do\n\s+grep -qx/.exec(run)?.[1] ?? "";
  assert.ok(required !== "" && !required.includes("ANTHROPIC_API_KEY"), "no corta el despliegue");
  // Sin el secreto en GitHub: si sigue en Supabase, aviso de que la traducción sigue prendida (borrarlo
  // de GitHub no lo saca de Supabase); si no está en ningún lado, aviso de que queda apagada.
  assert.match(
    run,
    /if \[ -z "\$\{ANTHROPIC_API_KEY:-\}" \]; then\n\s+if grep -qx "ANTHROPIC_API_KEY" <<< "\$\{names\}"; then\n\s+echo "::notice::ANTHROPIC_API_KEY no está en GitHub pero sigue en los secretos de Supabase[^\n]*supabase secrets unset ANTHROPIC_API_KEY[^\n]*"\n\s+else\n\s+echo "::warning::Sin ANTHROPIC_API_KEY la traducción automática de los platos queda apagada/,
  );
  assert.doesNotMatch(run, /echo[^\n]*\$\{?ANTHROPIC_API_KEY\b/, "ningún echo imprime el valor");

  const header = WORKFLOW.slice(0, WORKFLOW.indexOf("\nname: "));
  assert.match(header, /opcionales: [^)]*ANTHROPIC_API_KEY/);
  assert.match(header, /solo[\s#]+van el nombre y la descripción del plato/, "qué se manda a Anthropic");
  assert.match(header, /Borrar el secreto de GitHub no la saca de Supabase[\s\S]*?supabase secrets unset ANTHROPIC_API_KEY/);
});

test("TRANSLATE_TRANSPORT nunca en producción: el workflow no lo carga y, si está en Supabase, el despliegue corta", () => {
  // Con fake la función chef devolvería traducciones de mentira (además la función lo ignora fuera de
  // un Supabase local; contrato chef-api.md §8).
  assert.ok(!/TRANSLATE_TRANSPORT: \$\{\{/.test(WORKFLOW), "no se carga desde GitHub");
  const run = step("Secretos de la función");
  assert.match(run, /if grep -qx "TRANSLATE_TRANSPORT" <<< "\$\{names\}"; then\n\s+echo "::error::TRANSLATE_TRANSPORT está en los secretos de Supabase[^\n]*supabase secrets unset TRANSLATE_TRANSPORT[^\n]*"\n\s+exit 1\n\s+fi/);
});

test("la lista de secretos de Supabase: si no se puede leer, el despliegue corta (no pasa en silencio)", () => {
  const run = step("Secretos de la función");
  // El comando que falla y la lista vacía (o con otro formato) cortan, antes de los chequeos que dependen de ella.
  assert.match(run, /if ! listing=\$\(supabase secrets list --project-ref "\$\{SUPABASE_PROJECT_REF\}" -o json\); then\n\s+echo "::error::No se pudo leer la lista de secretos[^\n]*"\n\s+exit 1\n\s+fi/);
  assert.match(run, /if \[ -z "\$\{names\}" \]; then\n\s+echo "::error::La lista de secretos de la función vino vacía[^\n]*"\n\s+exit 1\n\s+fi/);
  assert.ok(!run.includes("::warning::No se pudo leer la lista"), "ya no es solo un aviso");
  const list = run.indexOf("supabase secrets list");
  for (const check of ['grep -qx "${name}" <<< "${names}"', 'grep -qx "TRANSLATE_TRANSPORT"', 'grep -qx "ANTHROPIC_API_KEY"']) {
    assert.ok(run.indexOf(check) > list, `${check} usa la lista leída`);
  }
});

// ---------------------------------------------------------------------------------------------
// PR04: Auth fijada desde el repo (contrato auth.md §3). El despliegue corta ANTES de db push.
// ---------------------------------------------------------------------------------------------
const AUTH_STEP = "Auth desde el repo (altas, código, SMTP y plantilla)";
const TRACKING_STEP = "Seguimiento de Resend apagado";
/** Un paso sin sus líneas de comentario (los que van antes del paso siguiente caen en este bloque). */
const code = (name: string): string =>
  step(name)
    .split("\n")
    .filter((line) => !/^\s*#/.test(line))
    .join("\n");

test("Auth y seguimiento de Resend: los dos pasos van antes de db push, con las credenciales del proyecto", () => {
  const migrations = WORKFLOW.indexOf("- name: Migraciones (db push)");
  const auth = WORKFLOW.indexOf(`- name: ${AUTH_STEP}`);
  const tracking = WORKFLOW.indexOf(`- name: ${TRACKING_STEP}`);
  assert.ok(tracking !== -1 && auth !== -1, "están los dos pasos");
  assert.ok(tracking < migrations && auth < migrations, "los dos antes de db push");
  assert.ok(tracking < auth, "el seguimiento se comprueba antes de tocar Auth");
  assert.match(step(TRACKING_STEP), /if: env\.HAS_SUPABASE == 'true'/);
});

test("seguimiento de Resend: con seguimiento de clics o de aperturas prendido, el paso falla (sin ignorar el resultado)", () => {
  const run = code(TRACKING_STEP);
  assert.match(run, /RESEND_API_KEY: \$\{\{ secrets\.RESEND_READ_KEY \|\| secrets\.RESEND_API_KEY \}\}/, "clave de lectura propia, con respaldo en la que ya existe");
  assert.match(run, /run: node supabase\/scripts\/resend-tracking\.ts$/m);
  assert.ok(!/\|\| true|continue-on-error/.test(run), "ningún resultado se ignora");
  assert.ok(!/echo[^\n]*RESEND_API_KEY/.test(run), "ningún echo imprime la clave");
  // Quien apaga el seguimiento es la dueña de la cuenta de Resend: el despliegue solo lo comprueba.
  assert.ok(!run.includes("PATCH") && !run.includes("-X "), "el despliegue no cambia nada en Resend");
  // Con una clave solo de envío no se puede leer: corta salvo una variable que lo confirme a propósito.
  assert.match(run, /RESEND_TRACKING_RESTRICTED_OK: \$\{\{ vars\.RESEND_TRACKING_RESTRICTED_OK \}\}/);
});

test("Auth: cada PATCH se vuelve a leer y se compara con el cuerpo pedido; un campo distinto corta antes de migrar", () => {
  const run = code(AUTH_STEP);
  assert.match(run, /^\s+set -euo pipefail$/m);
  // El cuerpo sale del script (que falla si config.toml prende autoconfirm) y no se lee en un `local`
  // que taparía el error.
  assert.match(run, /local body status[^\n]*\n\s+body=\$\(node supabase\/scripts\/auth-config\.ts "\$1"\)/);
  assert.ok(run.indexOf("body=$(node") < run.indexOf("-X PATCH"), "primero el cuerpo, después el PATCH");
  // La respuesta del PATCH (la configuración vigente) se compara con el cuerpo, parte por parte.
  assert.match(run, /node supabase\/scripts\/auth-config\.ts verify "\$1" < "\$\{response\}"/);
  const patchFn = /patch\(\) \{[\s\S]*?\n          \}\n/.exec(run)?.[0] ?? "";
  assert.ok(patchFn.includes('verify "$1"'), "dentro de patch(): ninguna parte queda sin verificar");
  assert.ok(patchFn.indexOf('verify "$1"') > patchFn.indexOf("-X PATCH"), "verifica lo que devolvió el PATCH");
  assert.match(patchFn, /Auth no quedó como pide el repo/);
  // Un verify fallido tiene que cortar: el `if !` termina en exit 1 (sin eso el paso seguiría hasta db push).
  assert.match(patchFn, /if ! node supabase\/scripts\/auth-config\.ts verify "\$1" < "\$\{response\}"; then\n\s+echo "::error::Auth no quedó como pide el repo[^\n]*\n\s+exit 1\n\s+fi/, "verify fallido: exit 1");
  // Las tres partes siguen: security siempre; smtp y templates con RESEND_SMTP_KEY.
  for (const part of ["security", "smtp", "templates"]) assert.match(run, new RegExp(`^\\s+patch ${part}$`, "m"));
  // Lo viejo se mantiene: las altas apagadas y la plantilla guardada.
  assert.match(run, /\.disable_signup == true/);
  assert.match(run, /mailer_templates_magic_link_content == \$template/);
});

test("Auth: una sola vez anota la versión de GoTrue y los campos que cambian, en el resumen y sin valores", () => {
  const run = code(AUTH_STEP);
  assert.match(run, /\$\{api\}\/health\?services=auth/, "la versión sale de la Management API");
  assert.match(run, /\.\[0\]\.info\.version/);
  assert.match(run, /auth-config\.ts changed "\$1" < "\$\{response\}"/, "los campos que cambian, antes de cada PATCH");
  assert.match(run, /GITHUB_STEP_SUMMARY/);
  // Se lee la configuración vigente antes del primer PATCH, para saber qué cambia.
  assert.ok(run.indexOf("-X GET") !== -1 && run.indexOf("-X GET") < run.indexOf("patch security"), "GET antes del primer PATCH");
  // Nada de la respuesta (trae la clave del SMTP) ni del cuerpo llega al log.
  assert.ok(!/cat "\$\{response\}"|cat "\$\{body\}"|echo "\$\{body\}"|echo "\$\{changed|set -x/.test(run), "no imprime ni la respuesta ni el cuerpo");
  const printers = run.split("\n").filter((line) => /\b(echo|printf)\b/.test(line) && /\$\{?(version|changed|all_changed)\b/.test(line));
  for (const line of printers) assert.match(line, /GITHUB_STEP_SUMMARY/, `se imprime fuera del resumen: ${line.trim()}`);
  // La versión que no se pudo leer avisa, pero no corta: no es un ajuste.
  assert.match(run, /::warning::[^\n]*versión de GoTrue/);
});

test("config.toml: el script sale con código 2 y el paso corta con set -e (el rechazo de autoconfirm en sí lo prueba auth-config.test.ts)", () => {
  // authSecurityConfig lanza (auth-config.test.ts) y la línea de comandos sale con 2: con set -e el paso corta.
  const script = readFileSync(repo("supabase/scripts/auth-config.ts"), "utf8");
  assert.match(script, /process\.exit\(2\)/);
  assert.match(step(AUTH_STEP), /set -euo pipefail/);
});

test("el encabezado del workflow remite a auth.md y dice que el seguimiento de Resend lo apaga la dueña de la cuenta", () => {
  const header = WORKFLOW.slice(0, WORKFLOW.indexOf("\nname: "));
  assert.match(header, /docs\/contracts\/auth\.md/);
  assert.match(header, /seguimiento de (clics|aperturas)/i);
});

test("hook de la cocina: antes del PATCH de Auth se comprueba que la función existe con sus grants, y si no, corta", () => {
  // El PATCH que prende el hook corre antes de db push: con un hook prendido que apunta a una función que no
  // está, nadie puede entrar. Por eso se mira la base de producción (Management API, solo lectura) primero.
  const check = WORKFLOW.indexOf('- name: "Hook de la cocina: la función existe"');
  const resend = WORKFLOW.indexOf("- name: Seguimiento de Resend apagado");
  const auth = WORKFLOW.indexOf("- name: Auth desde el repo");
  assert.ok(check !== -1 && auth !== -1, "están los dos pasos");
  assert.ok(check > resend && check < auth, "la comprobación corre antes del PATCH de Auth");
  assert.ok(auth < WORKFLOW.indexOf("- name: Migraciones (db push)"));
  const run = step('"Hook de la cocina: la función existe"');
  assert.match(run, /if: env\.HAS_SUPABASE == 'true'/);
  assert.match(run, /node supabase\/scripts\/auth-hook-check\.ts/);
  assert.match(run, /SUPABASE_PROJECT_REF: \$\{\{ vars\.SUPABASE_PROJECT_REF \}\}/);
  assert.ok(!run.includes("continue-on-error"), "si falla, corta");
  assert.ok(!/echo.*SUPABASE_ACCESS_TOKEN/.test(run), "nunca imprime el token");
});

test("captcha de Auth: la secreta se valida antes del PATCH y, después, Auth tiene que exigirlo, antes de migrar", () => {
  const secret = WORKFLOW.indexOf('- name: "Captcha de Auth: la secreta es la del widget"');
  const auth = WORKFLOW.indexOf("- name: Auth desde el repo");
  const enforced = WORKFLOW.indexOf('- name: "Captcha de Auth: Auth lo exige"');
  const migrations = WORKFLOW.indexOf("- name: Migraciones (db push)");
  assert.ok(secret !== -1 && enforced !== -1, "están los dos pasos del captcha");
  assert.ok(secret < auth && auth < enforced && enforced < migrations, "secreta → PATCH de Auth → Auth lo exige → db push");

  const before = step('"Captcha de Auth: la secreta es la del widget"');
  assert.match(before, /if: env\.HAS_SUPABASE == 'true'/);
  assert.match(before, /TURNSTILE_AUTH_SECRET_KEY: \$\{\{ secrets\.TURNSTILE_AUTH_SECRET_KEY \}\}/);
  assert.match(before, /node supabase\/scripts\/auth-captcha-check\.ts secret/);

  // El PATCH de security lleva la secreta (desde el secreto de GitHub, nunca una variable: las variables salen en claro).
  assert.match(step("Auth desde el repo"), /TURNSTILE_AUTH_SECRET_KEY: \$\{\{ secrets\.TURNSTILE_AUTH_SECRET_KEY \}\}/);
  assert.ok(!WORKFLOW.includes("vars.TURNSTILE_AUTH_SECRET_KEY"));

  const after = step('"Captcha de Auth: Auth lo exige"');
  assert.match(after, /if: env\.HAS_SUPABASE == 'true'/);
  assert.match(after, /SUPABASE_PUBLISHABLE_KEY: \$\{\{ vars\.SUPABASE_PUBLISHABLE_KEY \}\}/);
  assert.match(after, /node supabase\/scripts\/auth-captcha-check\.ts auth/);
  assert.ok(!/continue-on-error/.test(after), "si Auth no lo exige, el despliegue falla");
});
