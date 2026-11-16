// Colaboradores de la cocinera en producción: la lista del secreto CHEF_MEMBER_EMAILS (emails
// separados por coma). deploy-supabase.yml la aplica en cada despliegue, en el paso «Colaboradores de
// la cocinera» (deploy-accounts.sh members, al lado): crea las cuentas que faltan y llama a
// private.sync_chef_members (migración 20261116190000_chef_members.sql), que agrega a los que faltan y
// saca a los que ya no están. La lista manda: vacía o sin cargar, la cocina se queda sin colaboradores.
//
// Valida cada email antes de que llegue a una consulta (solo letras, números y . _ + - antes de la
// @; nada de comillas, barras ni espacios; tampoco %, que GitHub interpreta en ::add-mask::) y nunca
// lo escribe en un mensaje: los errores dicen la posición en la lista, y el workflow imprime solo la
// versión enmascarada.
//
// Uso (CI, desde la raíz), con CHEF_MEMBER_EMAILS y CHEF_LOGIN_EMAIL en el entorno:
//   node supabase/scripts/chef-members.ts list   → [{"email", "masked"}, …] en JSON
//   node supabase/scripts/chef-members.ts sql    → la llamada a private.sync_chef_members
// Con un error: el mensaje (sin emails) en stderr y código 2.
// Solo sintaxis borrable: corre con node, sin compilar.
import { pathToFileURL } from "node:url";

/** Tope de colaboradores (el mismo que private.sync_chef_members): es gente de confianza, pocos. */
export const MAX_MEMBERS = 10;

/** La regla del email, la misma que v_pattern de private.sync_chef_members (un test lo compara). */
export const MEMBER_EMAIL_PATTERN = "^[a-z0-9._+-]+@[a-z0-9.-]+\\.[a-z]{2,}$";
const MEMBER_EMAIL = new RegExp(MEMBER_EMAIL_PATTERN);
/** El largo máximo de un email (RFC 5321), como en la base. */
const MAX_EMAIL_LENGTH = 254;

export interface MemberEmail {
  /** En minúsculas y sin espacios. Va al SQL y a la API de Auth; nunca a un mensaje. */
  email: string;
  /** Lo que se puede imprimir: «p***@e***.com». */
  masked: string;
}

/** Un error de la lista. El mensaje nunca trae un email. */
export class MemberEmailsError extends Error {
  constructor(message: string) {
    super(`CHEF_MEMBER_EMAILS: ${message}`);
    this.name = "MemberEmailsError";
  }
}

function normalize(email: string): string {
  return email.trim().toLowerCase();
}

function isMemberEmail(email: string): boolean {
  return email.length <= MAX_EMAIL_LENGTH && MEMBER_EMAIL.test(email);
}

/** «persona@example.com» → «p***@e***.com»: la primera letra, la del dominio y la terminación. */
export function maskEmail(email: string): string {
  const at = email.lastIndexOf("@");
  const local = email.slice(0, at);
  const domain = email.slice(at + 1);
  const tld = domain.slice(domain.lastIndexOf(".") + 1);
  return `${local.slice(0, 1)}***@${domain.slice(0, 1)}***.${tld}`;
}

/**
 * La lista de CHEF_MEMBER_EMAILS: emails separados por coma (también sirven punto y coma, espacios y
 * saltos de línea), sin mayúsculas, espacios ni repetidos, en el orden en que vienen. Vacía o sin
 * cargar, ninguno. Lanza MemberEmailsError si alguno no es válido, si es el de la cocinera
 * ([chefEmail], CHEF_LOGIN_EMAIL: su cuenta nunca se toca) o si son más de MAX_MEMBERS.
 */
export function parseMemberEmails(raw: string | undefined, chefEmail?: string): MemberEmail[] {
  const entries = (raw ?? "").split(/[\s,;]+/).filter((entry) => entry !== "");
  const chef = chefEmail ? normalize(chefEmail) : "";
  const seen = new Set<string>();
  const members: MemberEmail[] = [];
  entries.forEach((entry, index) => {
    const email = normalize(entry);
    if (!isMemberEmail(email)) {
      throw new MemberEmailsError(
        `el email ${index + 1} no es válido (antes de la @ solo letras, números y . _ + -; después, un dominio)`,
      );
    }
    if (chef !== "" && email === chef) {
      throw new MemberEmailsError(`el email ${index + 1} es el de la cocinera (CHEF_LOGIN_EMAIL): no va en la lista`);
    }
    if (!seen.has(email)) {
      seen.add(email);
      members.push({ email, masked: maskEmail(email) });
    }
  });
  if (members.length > MAX_MEMBERS) {
    throw new MemberEmailsError(`hay más de ${MAX_MEMBERS} colaboradores`);
  }
  return members;
}

/**
 * La llamada a private.sync_chef_members con [emails], que ya pasaron por parseMemberEmails (si
 * alguno no cumple la regla, lanza: nada sin validar llega al SQL). Lista vacía: array[]::text[].
 */
export function syncMembersSql(emails: readonly string[]): string {
  for (const [index, email] of emails.entries()) {
    if (!isMemberEmail(email)) throw new MemberEmailsError(`el email ${index + 1} no es válido`);
  }
  const items = emails.map((email) => `'${email}'`).join(", ");
  return `select private.sync_chef_members(array[${items}]::text[]) as result`;
}

// Uso desde la línea de comandos: lo que imprime va a una variable del workflow, nunca al log.
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const command = process.argv[2];
    if (command !== "list" && command !== "sql") {
      throw new Error("Uso: node supabase/scripts/chef-members.ts list|sql");
    }
    const members = parseMemberEmails(process.env.CHEF_MEMBER_EMAILS, process.env.CHEF_LOGIN_EMAIL);
    process.stdout.write(
      command === "list" ? JSON.stringify(members) : syncMembersSql(members.map((member) => member.email)),
    );
  } catch (error) {
    process.stderr.write(`${error instanceof Error ? error.message : "error"}\n`);
    process.exit(2);
  }
}
