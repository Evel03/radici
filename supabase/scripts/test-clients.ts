// Cuentas de prueba de clienta en producción (auth.md §15): la lista del secreto TEST_CLIENT_EMAILS
// (emails separados por coma). deploy-supabase.yml la aplica en cada despliegue, en el paso «Cuentas de
// prueba» (deploy-accounts.sh testers, al lado): crea las cuentas que faltan, confirmadas y sin
// contraseña, y llama a private.sync_test_clients (migración 20261127120000_test_clients.sql), que marca
// a las de la lista con app_metadata.radici_test y saca a las que ya no están. La lista manda: vacía o
// sin cargar, no queda ninguna cuenta de prueba.
//
// Misma validación que chef-members.ts (y la misma regla del email que la base): ningún email llega a
// una consulta sin validar ni sale en un mensaje (los errores dicen la posición en la lista). Ninguno
// puede ser de la cocina: ni CHEF_LOGIN_EMAIL ni uno de CHEF_MEMBER_EMAILS (la base lo vuelve a
// comprobar con las cuentas reales).
//
// Uso (CI, desde la raíz), con TEST_CLIENT_EMAILS, CHEF_LOGIN_EMAIL y CHEF_MEMBER_EMAILS en el entorno:
//   node supabase/scripts/test-clients.ts list   → [{"email", "masked"}, …] en JSON
//   node supabase/scripts/test-clients.ts sql    → la llamada a private.sync_test_clients
// Con un error: el mensaje (sin emails) en stderr y código 2.
// Solo sintaxis borrable: corre con node, sin compilar.
import { pathToFileURL } from "node:url";
import { MEMBER_EMAIL_PATTERN, maskEmail, parseMemberEmails, type MemberEmail } from "./chef-members.ts";

/** Tope de cuentas de prueba (el mismo que private.sync_test_clients). */
export const MAX_TEST_CLIENTS = 10;

/** La regla del email: la de los colaboradores y la de v_pattern en private.sync_test_clients. */
export const TEST_EMAIL_PATTERN = MEMBER_EMAIL_PATTERN;
const TEST_EMAIL = new RegExp(TEST_EMAIL_PATTERN);
const MAX_EMAIL_LENGTH = 254;

/** Un error de la lista. El mensaje nunca trae un email. */
export class TestClientEmailsError extends Error {
  constructor(message: string) {
    super(`TEST_CLIENT_EMAILS: ${message}`);
    this.name = "TestClientEmailsError";
  }
}

function isTestEmail(email: string): boolean {
  return email.length <= MAX_EMAIL_LENGTH && TEST_EMAIL.test(email);
}

/**
 * La lista de TEST_CLIENT_EMAILS: emails separados por coma (también punto y coma, espacios y saltos
 * de línea), en minúsculas, sin repetidos y en el orden en que vienen. Vacía o sin cargar, ninguna.
 * Lanza TestClientEmailsError si alguno no es válido, si es de la cocina ([chefEmail] o uno de
 * [memberEmails], ya validados por chef-members.ts) o si son más de MAX_TEST_CLIENTS.
 */
export function parseTestClientEmails(
  raw: string | undefined,
  chefEmail?: string,
  memberEmails: readonly MemberEmail[] = [],
): MemberEmail[] {
  const kitchen = new Set(memberEmails.map((member) => member.email));
  if (chefEmail) kitchen.add(chefEmail.trim().toLowerCase());
  const entries = (raw ?? "").split(/[\s,;]+/).filter((entry) => entry !== "");
  const seen = new Set<string>();
  const testers: MemberEmail[] = [];
  entries.forEach((entry, index) => {
    const email = entry.trim().toLowerCase();
    if (!isTestEmail(email)) {
      throw new TestClientEmailsError(
        `el email ${index + 1} no es válido (antes de la @ solo letras, números y . _ + -; después, un dominio)`,
      );
    }
    if (kitchen.has(email)) {
      throw new TestClientEmailsError(
        `el email ${index + 1} es de la cocina (CHEF_LOGIN_EMAIL o CHEF_MEMBER_EMAILS): una cuenta de la cocina nunca es de prueba`,
      );
    }
    if (!seen.has(email)) {
      seen.add(email);
      testers.push({ email, masked: maskEmail(email) });
    }
  });
  if (testers.length > MAX_TEST_CLIENTS) {
    throw new TestClientEmailsError(`hay más de ${MAX_TEST_CLIENTS} cuentas de prueba`);
  }
  return testers;
}

/**
 * La llamada a private.sync_test_clients con [emails], que ya pasaron por parseTestClientEmails (si
 * alguno no cumple la regla, lanza: nada sin validar llega al SQL). Lista vacía: array[]::text[].
 */
export function syncTestClientsSql(emails: readonly string[]): string {
  for (const [index, email] of emails.entries()) {
    if (!isTestEmail(email)) throw new TestClientEmailsError(`el email ${index + 1} no es válido`);
  }
  const items = emails.map((email) => `'${email}'`).join(", ");
  return `select private.sync_test_clients(array[${items}]::text[]) as result`;
}

// Uso desde la línea de comandos: lo que imprime va a una variable del workflow, nunca al log.
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const command = process.argv[2];
    if (command !== "list" && command !== "sql") {
      throw new Error("Uso: node supabase/scripts/test-clients.ts list|sql");
    }
    const members = parseMemberEmails(process.env.CHEF_MEMBER_EMAILS, process.env.CHEF_LOGIN_EMAIL);
    const testers = parseTestClientEmails(process.env.TEST_CLIENT_EMAILS, process.env.CHEF_LOGIN_EMAIL, members);
    process.stdout.write(
      command === "list" ? JSON.stringify(testers) : syncTestClientsSql(testers.map((tester) => tester.email)),
    );
  } catch (error) {
    process.stderr.write(`${error instanceof Error ? error.message : "error"}\n`);
    process.exit(2);
  }
}
