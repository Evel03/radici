// curl falso para deploy-accounts.test.ts: responde, sin red ni base, lo que deploy-accounts.sh le pide a
// la Management API de Supabase (SQL como postgres y las claves del proyecto) y a la API de
// administración de Auth (crear una cuenta). El estado (cocineras, cuentas de Auth y colaboradores) vive
// en el JSON de FAKE_STATE, porque cada llamada es un proceso nuevo, y cada llamada se anota, en una
// línea JSON, en FAKE_LOG. Una consulta o una ruta que no conoce responde 400 o 404: así un cambio del
// script que haga otra cosa se nota en los tests.
// Entiende lo que usa el script: -sS, --fail-with-body (con un 4xx o 5xx sale con 22 y deja el cuerpo),
// -X, -H, -o, -w '%{http_code}' y --data-binary @-.
// Solo sintaxis borrable: corre con node, sin compilar.
import { appendFileSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

export interface FakeUser {
  email: string;
  confirmed: boolean;
  locale?: string;
}

export interface FakeState {
  /** Emails de las cocineras (public.chefs). */
  chefs: string[];
  /** Cuentas de Auth. */
  users: FakeUser[];
  /** Emails de los colaboradores (public.chef_members). */
  members: string[];
  /** Cuentas que sync_chef_members no puede borrar (una ficha de cliente, permisos): quedan en Auth. */
  undeletable?: string[];
  /** Respuesta forzada de Auth al crear una cuenta (por ejemplo, 500). */
  adminStatus?: number;
}

/** Una llamada anotada en FAKE_LOG. */
export interface FakeCall {
  method: string;
  url: string;
  query?: string;
  body?: unknown;
  headers?: string[];
}

/** La clave secreta del proyecto falso: Auth exige esta en apikey. */
export const FAKE_SECRET_KEY = "sb_secret_clave_de_prueba_123";

function fail(message: string): never {
  process.stderr.write(`curl falso: ${message}\n`);
  process.exit(2);
}

function main(): void {
  const args = process.argv.slice(2);
  let method = "GET";
  let out: string | null = null;
  let writeOut: string | null = null;
  let url = "";
  let data: string | null = null;
  let failWithBody = false;
  const headers: string[] = [];
  for (let i = 0; i < args.length; i++) {
    const arg = args[i] ?? "";
    if (arg === "-sS" || arg === "-s" || arg === "-S") continue;
    if (arg === "--fail-with-body") failWithBody = true;
    else if (arg === "-X") method = args[++i] ?? "";
    else if (arg === "-H") headers.push(args[++i] ?? "");
    else if (arg === "-o") out = args[++i] ?? null;
    else if (arg === "-w") writeOut = args[++i] ?? null;
    else if (arg === "--data-binary") data = args[++i] ?? null;
    else if (arg.startsWith("-")) fail(`opción no simulada: ${arg}`);
    else url = arg;
  }
  const body = data === "@-" ? readFileSync(0, "utf8") : data;
  const statePath = process.env.FAKE_STATE ?? fail("falta FAKE_STATE");
  const logPath = process.env.FAKE_LOG ?? fail("falta FAKE_LOG");
  const state = JSON.parse(readFileSync(statePath, "utf8")) as FakeState;
  const path = url.replace(/\?.*$/, "");

  function save(): void {
    writeFileSync(statePath, JSON.stringify(state, null, 2));
  }
  function log(call: FakeCall): void {
    appendFileSync(logPath, `${JSON.stringify(call)}\n`);
  }
  function respond(status: number, json: unknown): never {
    const text = JSON.stringify(json);
    if (out) writeFileSync(out, text);
    else process.stdout.write(text);
    if (writeOut === "%{http_code}") process.stdout.write(String(status));
    process.exit(failWithBody && status >= 400 ? 22 : 0);
  }
  function userOf(email: string): FakeUser | undefined {
    return state.users.find((user) => user.email === email.toLowerCase());
  }
  function rows(value: number): never {
    return respond(201, [{ n: value }]);
  }

  if (method === "POST" && /^https:\/\/api\.supabase\.com\/v1\/projects\/[^/]+\/database\/query$/.test(path)) {
    const query = String((JSON.parse(body ?? "{}") as { query?: unknown }).query ?? "");
    log({ method, url: path, query });
    if (query === "select count(*)::int as n from public.chefs") rows(state.chefs.length);
    if (query === "select count(*)::int as n from public.chef_members") rows(state.members.length);
    if (query === "select count(*)::int as n from auth.users") rows(state.users.length);
    const usersWith = /^select count\(\*\)::int as n from auth\.users where lower\(email\) = lower\('([^']*)'\)( and email_confirmed_at is null)?$/.exec(query);
    if (usersWith) {
      const email = (usersWith[1] ?? "").toLowerCase();
      const onlyUnconfirmed = usersWith[2] !== undefined;
      rows(state.users.filter((user) => user.email === email && (!onlyUnconfirmed || !user.confirmed)).length);
    }
    const promote = /^select public\.promote_to_chef\('([^']*)', '([^']*)'\)$/.exec(query);
    if (promote) {
      const user = userOf(promote[1] ?? "");
      if (user === undefined) return respond(400, { message: "user_not_found" });
      if (!user.confirmed) return respond(400, { message: "user_not_confirmed" });
      state.chefs.push(user.email);
      save();
      respond(201, [{ promote_to_chef: null }]);
    }
    if (query === "select private.add_default_availability() as n") rows(5);
    const sync = /^select private\.sync_chef_members\(array\[(.*)\]::text\[\]\) as result$/.exec(query);
    if (sync) {
      // Las mismas validaciones que la base, antes de cambiar nada.
      const emails = [...(sync[1] ?? "").matchAll(/'([^']*)'/g)].map((match) => match[1] ?? "");
      if (state.chefs.length === 0) respond(400, { message: "chef_not_found" });
      if (state.chefs.length > 1) respond(400, { message: "single_chef_required" });
      if (emails.some((email) => state.chefs.includes(email))) respond(400, { message: "chef_email_not_member" });
      for (const email of emails) {
        const user = userOf(email);
        if (user === undefined) return respond(400, { message: "member_user_not_found" });
        if (!user.confirmed) return respond(400, { message: "member_user_not_confirmed" });
      }
      const removed = state.members.filter((email) => !emails.includes(email));
      const kept = state.members.filter((email) => emails.includes(email));
      const added = emails.filter((email) => !state.members.includes(email));
      const deleted = removed.filter((email) => !(state.undeletable ?? []).includes(email));
      state.users = state.users.filter((user) => !deleted.includes(user.email));
      state.members = [...kept, ...added];
      save();
      respond(201, [{
        result: { members: emails.length, added: added.length, kept: kept.length, removed: removed.length, accounts_deleted: deleted.length },
      }]);
    }
    respond(400, { message: "consulta no simulada" });
  }

  log({ method, url: path, body: body ? JSON.parse(body) : undefined, headers });
  if (method === "GET" && /^https:\/\/api\.supabase\.com\/v1\/projects\/[^/]+\/api-keys$/.test(path)) {
    respond(200, [
      { name: "anon", type: "legacy", api_key: "eyJ.clave.anon" },
      { name: "default", type: "secret", api_key: FAKE_SECRET_KEY },
    ]);
  }
  if (method === "POST" && /^https:\/\/[^/]+\.supabase\.co\/auth\/v1\/admin\/users$/.test(path)) {
    if (!headers.includes(`apikey: ${FAKE_SECRET_KEY}`)) respond(401, { msg: "sin la clave secreta" });
    if (state.adminStatus) respond(state.adminStatus, { msg: "error simulado" });
    const created = JSON.parse(body ?? "{}") as { email: string; email_confirm?: boolean; user_metadata?: { locale?: string } };
    if (userOf(created.email)) respond(422, { msg: "email_exists" });
    state.users.push({ email: created.email.toLowerCase(), confirmed: created.email_confirm === true, locale: created.user_metadata?.locale });
    save();
    respond(200, { id: `id-${state.users.length}`, email: created.email });
  }
  respond(404, { message: `ruta no simulada: ${method} ${path}` });
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) main();
