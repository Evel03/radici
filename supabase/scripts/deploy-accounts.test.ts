// Tests de deploy-accounts.sh (al lado), el script de los pasos «Cuenta de la cocinera (solo la primera
// vez)» y «Colaboradores de la cocinera» de deploy-supabase.yml. Lo corren de verdad, con bash, y un curl
// falso (deploy-accounts.fake-api.ts) en lugar de la Management API y de Auth: sin red ni base.
// Correr con: npm test (raíz). Necesita bash, jq y openssl, como el runner de ubuntu del CI: si falta
// alguno, se saltea. En Windows corre solo desde Git Bash (MSYSTEM): desde PowerShell, el bash del PATH
// es el de WSL.
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { delimiter, join } from "node:path";
import { fileURLToPath } from "node:url";
import { syncMembersSql } from "./chef-members.ts";
import { FAKE_SECRET_KEY, type FakeCall, type FakeState } from "./deploy-accounts.fake-api.ts";

const REPO = fileURLToPath(new URL("../../", import.meta.url));
const FAKE_API = fileURLToPath(new URL("./deploy-accounts.fake-api.ts", import.meta.url)).replaceAll("\\", "/");

function unavailable(): string | false {
  if (process.platform === "win32" && !process.env.MSYSTEM) {
    return "en Windows, solo desde Git Bash (el bash de PowerShell es el de WSL)";
  }
  const probe = spawnSync("bash", ["-c", "command -v jq && command -v openssl"], { encoding: "utf8" });
  return probe.status === 0 ? false : "faltan bash, jq u openssl (el runner del CI los tiene)";
}
const skip = unavailable();

const EVELYN = "evelyn@ejemplo.test";
const SOCIO = "socio@ejemplo.test";
const NUEVA = "nueva@ejemplo.test";
const VIEJO = "viejo@ejemplo.test";
const confirmed = (email: string) => ({ email, confirmed: true });

interface Run {
  code: number | null;
  /** stdout y stderr juntos, como en el log del paso. */
  out: string;
  state: FakeState;
  calls: FakeCall[];
}

/** Corre `bash supabase/scripts/deploy-accounts.sh <command>` desde la raíz, con el curl falso. */
function accounts(command: "chef" | "members", state: FakeState, env: Record<string, string> = {}): Run {
  const dir = mkdtempSync(join(tmpdir(), "deploy-accounts-"));
  try {
    const bin = join(dir, "bin");
    const fakeCurl = join(bin, "curl");
    mkdirSync(bin);
    writeFileSync(fakeCurl, `#!/usr/bin/env bash\nexec node "${FAKE_API}" "$@"\n`);
    chmodSync(fakeCurl, 0o755);
    const statePath = join(dir, "state.json");
    const logPath = join(dir, "calls.log");
    writeFileSync(statePath, JSON.stringify(state));
    writeFileSync(logPath, "");
    const result = spawnSync("bash", ["supabase/scripts/deploy-accounts.sh", command], {
      cwd: REPO,
      encoding: "utf8",
      env: {
        ...process.env,
        PATH: `${bin}${delimiter}${process.env.PATH ?? ""}`,
        FAKE_STATE: statePath,
        FAKE_LOG: logPath,
        SUPABASE_PROJECT_REF: "proyectodeprueba",
        SUPABASE_ACCESS_TOKEN: "sbp_0000000000000000000000000000000000000000",
        CHEF_LOGIN_EMAIL: "",
        CHEF_DISPLAY_NAME: "",
        CHEF_LOCALE: "",
        CHEF_MEMBER_EMAILS: "",
        ...env,
      },
    });
    const calls = readFileSync(logPath, "utf8")
      .split("\n")
      .filter((line) => line !== "")
      .map((line) => JSON.parse(line) as FakeCall);
    return {
      code: result.status,
      out: `${result.stdout ?? ""}${result.stderr ?? ""}`,
      state: JSON.parse(readFileSync(statePath, "utf8")) as FakeState,
      calls,
    };
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

const syncCalls = (run: Run): string[] =>
  run.calls.map((call) => call.query ?? "").filter((query) => query.includes("sync_chef_members"));
const accountsCreated = (run: Run): FakeCall[] => run.calls.filter((call) => call.url.endsWith("/auth/v1/admin/users"));

/** Ninguna línea del log, salvo ::add-mask::, lleva uno de estos emails (ni en mayúsculas). */
function assertNoEmails(out: string, emails: string[]): void {
  const leaks = out
    .split("\n")
    .filter((line) => !line.startsWith("::add-mask::"))
    .filter((line) => emails.some((email) => line.toLowerCase().includes(email)));
  assert.deepEqual(leaks, [], "líneas con un email");
}

test("colaboradores: crea la cuenta que falta, aplica la lista con el SQL de chef-members.ts y cuenta los usuarios", { skip }, () => {
  const run = accounts(
    "members",
    { chefs: [EVELYN], users: [confirmed(EVELYN), confirmed(SOCIO), confirmed(VIEJO)], members: [SOCIO, VIEJO] },
    { CHEF_MEMBER_EMAILS: ` ${SOCIO}, Nueva@Ejemplo.test`, CHEF_LOGIN_EMAIL: EVELYN },
  );
  assert.equal(run.code, 0, run.out);

  // Cada email se enmascara antes de usarlo, y la clave secreta, apenas se lee.
  const firstUse = run.out.indexOf("Cuenta creada");
  for (const value of [SOCIO, NUEVA, FAKE_SECRET_KEY]) {
    const mask = run.out.indexOf(`::add-mask::${value}\n`);
    assert.ok(mask !== -1 && mask < firstUse, `${value} se enmascara antes de usarlo`);
  }

  // Una sola cuenta nueva, confirmada, con contraseña al azar y el idioma por defecto.
  const created = accountsCreated(run);
  assert.equal(created.length, 1);
  const body = created[0]?.body as { email: string; password: string; email_confirm: boolean; user_metadata: { locale: string } };
  assert.equal(body.email, NUEVA);
  assert.equal(body.email_confirm, true);
  assert.match(body.password, /^[0-9a-f]{64}$/);
  assert.deepEqual(body.user_metadata, { locale: "es" });
  assert.equal(run.calls.filter((call) => call.url.endsWith("/api-keys")).length, 1, "la clave se lee una sola vez");

  // Una sola sincronización, con la lista entera: la lista manda (el viejo sale y su cuenta se borra).
  assert.deepEqual(syncCalls(run), [syncMembersSql([SOCIO, NUEVA])]);
  assert.deepEqual(run.state.members, [SOCIO, NUEVA]);
  assert.deepEqual(run.state.users.map((user) => user.email), [EVELYN, SOCIO, NUEVA]);
  assert.match(run.out, /^Cuenta creada para el colaborador n\*\*\*@e\*\*\*\.test\.$/m);
  assert.match(run.out, /^Colaboradores: 2 en la lista \(nuevos: 1; sin cambios: 1; salieron: 1; cuentas borradas: 1\)\.$/m);
  assert.match(run.out, /^Usuarios en Auth: 3 \(cocinera: 1; colaboradores: 2\)\.$/m);
  assert.doesNotMatch(run.out, /::warning::Hay/);
  assert.doesNotMatch(run.out, /::error::/);
  assertNoEmails(run.out, [EVELYN, SOCIO, NUEVA, VIEJO]);
});

test("colaboradores: con la lista cargada y las cuentas al día no avisa nada; vacía, saca a todos", { skip }, () => {
  const state: FakeState = { chefs: [EVELYN], users: [confirmed(EVELYN), confirmed(SOCIO)], members: [SOCIO] };
  const loaded = accounts("members", state, { CHEF_MEMBER_EMAILS: SOCIO });
  assert.equal(loaded.code, 0, loaded.out);
  assert.doesNotMatch(loaded.out, /::warning::/);

  // Lista vacía (o el secreto sin cargar): saca a todos, sin crear cuentas ni leer la clave secreta.
  const empty = accounts("members", state);
  assert.equal(empty.code, 0, empty.out);
  assert.deepEqual(syncCalls(empty), [syncMembersSql([])]);
  assert.deepEqual(empty.state.members, []);
  assert.equal(empty.calls.filter((call) => !call.query).length, 0, "ni la clave secreta ni Auth");
  assert.match(empty.out, /^Colaboradores: 0 en la lista \(nuevos: 0; sin cambios: 0; salieron: 1; cuentas borradas: 1\)\.$/m);
  assert.match(empty.out, /^Usuarios en Auth: 1 \(cocinera: 1; colaboradores: 0\)\.$/m);
});

test("colaboradores: sin cocinera solo avisa (la lista se aplica en el despliegue que la cree)", { skip }, () => {
  const run = accounts("members", { chefs: [], users: [], members: [] }, { CHEF_MEMBER_EMAILS: SOCIO });
  assert.equal(run.code, 0, run.out);
  assert.match(run.out, /^::warning::Sin cocinera no hay de quién ser colaborador/m);
  assert.deepEqual(syncCalls(run), []);
  assert.equal(accountsCreated(run).length, 0);
  assert.match(run.out, /^Usuarios en Auth: 0 \(cocinera: 0; colaboradores: 0\)\.$/m);
});

test("colaboradores: una cuenta que ya existe sin confirmar corta el paso, con el email enmascarado y sin sincronizar", { skip }, () => {
  const run = accounts(
    "members",
    { chefs: [EVELYN], users: [confirmed(EVELYN), { email: SOCIO, confirmed: false }], members: [] },
    { CHEF_MEMBER_EMAILS: SOCIO },
  );
  assert.equal(run.code, 1, run.out);
  assert.match(run.out, /^::error::Ya hay una cuenta del colaborador s\*\*\*@e\*\*\*\.test sin confirmar/m);
  assert.deepEqual(syncCalls(run), []);
  assertNoEmails(run.out, [SOCIO]);
});

test("colaboradores: una lista inválida (o con el email de la cocinera) corta antes de tocar nada, sin repetirla", { skip }, () => {
  for (const env of [
    { CHEF_MEMBER_EMAILS: `${SOCIO},x');delete from public.chefs;--@a.it` },
    { CHEF_MEMBER_EMAILS: `${SOCIO},por%ciento@ejemplo.test` },
    { CHEF_MEMBER_EMAILS: `${SOCIO},${EVELYN}`, CHEF_LOGIN_EMAIL: EVELYN },
  ]) {
    const run = accounts("members", { chefs: [EVELYN], users: [confirmed(EVELYN)], members: [] }, env);
    assert.equal(run.code, 1, run.out);
    assert.match(run.out, /^::error::CHEF_MEMBER_EMAILS no es una lista válida/m);
    assert.deepEqual(run.calls, [], "ni una consulta");
    assertNoEmails(run.out, [SOCIO, EVELYN, "delete from", "por%ciento"]);
  }
});

test("colaboradores: un error de Auth o de la base corta el paso sin mostrar emails", { skip }, () => {
  const auth = accounts(
    "members",
    { chefs: [EVELYN], users: [confirmed(EVELYN)], members: [], adminStatus: 500 },
    { CHEF_MEMBER_EMAILS: NUEVA },
  );
  assert.equal(auth.code, 1, auth.out);
  assert.match(auth.out, /^::error::No se pudo crear la cuenta del colaborador n\*\*\*@e\*\*\*\.test \(500\)/m);
  assert.deepEqual(syncCalls(auth), []);

  // Sin CHEF_LOGIN_EMAIL el script no puede reconocer el email de la cocinera: lo frena la base.
  const base = accounts("members", { chefs: [EVELYN], users: [confirmed(EVELYN)], members: [] }, { CHEF_MEMBER_EMAILS: EVELYN });
  assert.equal(base.code, 1, base.out);
  assert.match(base.out, /^::error::Falló una consulta a la base: chef_email_not_member$/m);
  assert.deepEqual(base.state.chefs, [EVELYN]);
  for (const run of [auth, base]) assertNoEmails(run.out, [EVELYN, NUEVA]);
});

test("colaboradores: avisa si en Auth hay alguien más que la cocinera y sus colaboradores", { skip }, () => {
  // Una cuenta que salió de la lista y no se pudo borrar (permisos) y no tiene ficha de cliente queda de más.
  const run = accounts(
    "members",
    { chefs: [EVELYN], users: [confirmed(EVELYN), confirmed(SOCIO), confirmed(VIEJO)], members: [SOCIO, VIEJO], undeletable: [VIEJO] },
    { CHEF_MEMBER_EMAILS: SOCIO },
  );
  assert.equal(run.code, 0, run.out);
  assert.match(run.out, /cuentas borradas: 0\)\.$/m);
  assert.match(run.out, /^::warning::Hay 1 usuarios en Auth que no son la cocinera, ni sus colaboradores, ni tienen ficha de cliente/m);
});

test("colaboradores: el aviso de usuarios de más cuenta solo a quien no tiene ficha (con una clienta con ficha y otra sin)", { skip }, () => {
  const run = accounts(
    "members",
    {
      chefs: [EVELYN],
      users: [confirmed(EVELYN), { email: "clienta@gmail.com", confirmed: true, client: true }, { email: "suelta@gmail.com", confirmed: true }],
      members: [],
    },
  );
  assert.equal(run.code, 0, run.out);
  assert.match(run.out, /^::warning::Hay 1 usuarios en Auth que no son la cocinera/m);
});

const OTRA = "otra@ejemplo.test";

test("colaboradores: dos cocinas cortan el paso antes de crear cuentas o sincronizar", { skip }, () => {
  const run = accounts(
    "members",
    { chefs: [EVELYN, OTRA], users: [confirmed(EVELYN), confirmed(OTRA)], members: [] },
    { CHEF_MEMBER_EMAILS: NUEVA },
  );
  assert.equal(run.code, 1, run.out);
  assert.match(run.out, /^::error::Hay 2 cocinas en public\.chefs y tiene que haber una sola/m);
  assert.deepEqual(syncCalls(run), []);
  assert.equal(accountsCreated(run).length, 0);
  assertNoEmails(run.out, [EVELYN, OTRA, NUEVA]);
});

test("colaboradores: un usuario anónimo corta el paso, pero después de aplicar la lista (una baja no espera)", { skip }, () => {
  const run = accounts(
    "members",
    { chefs: [EVELYN], users: [confirmed(EVELYN), { email: "", confirmed: false, anonymous: true }], members: [] },
  );
  assert.equal(run.code, 1, run.out);
  assert.match(run.out, /^::error::Hay 1 usuarios anónimos en Auth/m);
  assert.deepEqual(syncCalls(run), [syncMembersSql([])]);
});

test("colaboradores: si después de sincronizar chef_members no es la lista (de más o de menos) corta el paso", { skip }, () => {
  // Un colaborador de más: la base dice que sync dejó a VIEJO, que no está en la lista.
  const extra = accounts(
    "members",
    { chefs: [EVELYN], users: [confirmed(EVELYN), confirmed(SOCIO), confirmed(VIEJO)], members: [SOCIO, VIEJO], syncIgnored: true },
    { CHEF_MEMBER_EMAILS: SOCIO },
  );
  assert.equal(extra.code, 1, extra.out);
  assert.match(extra.out, /^::error::Los colaboradores en la base \(2\) no son los de la lista \(1\)/m);

  // Un colaborador de menos: falta SOCIO.
  const missing = accounts(
    "members",
    { chefs: [EVELYN], users: [confirmed(EVELYN), confirmed(SOCIO)], members: [], syncIgnored: true },
    { CHEF_MEMBER_EMAILS: SOCIO },
  );
  assert.equal(missing.code, 1, missing.out);
  assert.match(missing.out, /^::error::Los colaboradores en la base \(0\) no son los de la lista \(1\)/m);

  // Misma cantidad pero otra persona: tampoco pasa.
  const swapped = accounts(
    "members",
    { chefs: [EVELYN], users: [confirmed(EVELYN), confirmed(SOCIO), confirmed(VIEJO)], members: [VIEJO], syncIgnored: true },
    { CHEF_MEMBER_EMAILS: SOCIO },
  );
  assert.equal(swapped.code, 1, swapped.out);
  assert.match(swapped.out, /^::error::Los colaboradores en la base \(1\) no son los de la lista \(1\)/m);
  for (const run of [extra, missing, swapped]) assertNoEmails(run.out, [EVELYN, SOCIO, VIEJO]);
});

test("colaboradores: avisa, sin cortar, si una cuenta de la cocina tiene una identidad que no es de email", { skip }, () => {
  const run = accounts(
    "members",
    {
      chefs: [EVELYN],
      users: [{ email: EVELYN, confirmed: true, providers: ["email", "google"] }, confirmed(SOCIO)],
      members: [SOCIO],
    },
    { CHEF_MEMBER_EMAILS: SOCIO },
  );
  assert.equal(run.code, 0, run.out);
  assert.match(run.out, /^::warning::1 identidades de las cuentas de la cocina no son de email/m);
  assertNoEmails(run.out, [EVELYN, SOCIO]);
});

test("colaboradores: informa cuántas cuentas hay de clientas, de prueba y sin confirmar, solo con números", { skip }, () => {
  const run = accounts(
    "members",
    {
      chefs: [EVELYN],
      users: [
        confirmed(EVELYN),
        { email: "clienta1@gmail.com", confirmed: true, client: true },
        { email: "clienta2@ejemplo.test", confirmed: true, client: true },
        { email: "clienta3@gmail.com", confirmed: false, client: true },
      ],
      members: [],
    },
  );
  assert.equal(run.code, 0, run.out);
  assert.match(run.out, /^Cuentas de clientas: 3 \(de prueba: 1; sin confirmar: 1\)\.$/m);
  assert.doesNotMatch(run.out, /::warning::/);
  assertNoEmails(run.out, [EVELYN, "clienta1", "clienta2", "clienta3"]);
});

test("cocinera: la primera vez crea la cuenta, la promueve y le carga el horario", { skip }, () => {
  const run = accounts("chef", { chefs: [], users: [], members: [] }, {
    CHEF_LOGIN_EMAIL: EVELYN,
    CHEF_DISPLAY_NAME: "Evelyn",
    CHEF_LOCALE: "it",
  });
  assert.equal(run.code, 0, run.out);
  const created = accountsCreated(run);
  assert.equal(created.length, 1);
  assert.deepEqual(
    (created[0]?.body as { email_confirm: boolean; user_metadata: unknown }).user_metadata,
    { locale: "it" },
  );
  const queries = run.calls.map((call) => call.query).filter((query): query is string => query !== undefined);
  const promote = queries.indexOf(`select public.promote_to_chef('${EVELYN}', 'Evelyn')`);
  assert.ok(promote !== -1 && queries.indexOf("select private.add_default_availability() as n") > promote,
    "el horario inicial, justo después de promote_to_chef");
  assert.deepEqual(run.state.chefs, [EVELYN]);
  assert.match(run.out, /^Cocinera creada\. Horario inicial cargado: 5 reglas/m);
  assert.ok(!queries.some((query) => query.includes("chef_members")), "los colaboradores son de su propio paso");
});

test("cocinera: con una ya creada no toca nada; sin las variables, solo avisa", { skip }, () => {
  const existing = accounts("chef", { chefs: [EVELYN], users: [confirmed(EVELYN)], members: [] }, {
    CHEF_LOGIN_EMAIL: EVELYN,
    CHEF_DISPLAY_NAME: "Evelyn",
  });
  assert.equal(existing.code, 0, existing.out);
  assert.match(existing.out, /^Ya hay cocinera: no se toca/m);
  assert.deepEqual(existing.calls.map((call) => call.query), ["select count(*)::int as n from public.chefs"]);

  const missing = accounts("chef", { chefs: [], users: [], members: [] });
  assert.equal(missing.code, 0, missing.out);
  assert.match(missing.out, /^::warning::Todavía no hay cocinera y faltan las variables/m);
  assert.equal(missing.calls.length, 1);
});

test("cocinera: una cuenta con su email sin confirmar corta el paso antes de promoverla", { skip }, () => {
  const run = accounts("chef", { chefs: [], users: [{ email: EVELYN, confirmed: false }], members: [] }, {
    CHEF_LOGIN_EMAIL: EVELYN,
    CHEF_DISPLAY_NAME: "Evelyn",
  });
  assert.equal(run.code, 1, run.out);
  assert.match(run.out, /^::error::Ya hay una cuenta con .* sin confirmar/m);
  assert.ok(!run.calls.some((call) => call.query?.includes("promote_to_chef")));
});

test("sin subcomando (o con otro): código 2 y el uso", { skip }, () => {
  const run = accounts("otra" as "chef", { chefs: [], users: [], members: [] });
  assert.equal(run.code, 2, run.out);
  assert.match(run.out, /Uso: bash supabase\/scripts\/deploy-accounts\.sh chef\|members/);
  assert.deepEqual(run.calls, []);
});
