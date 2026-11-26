// El email de la cuenta, enmascarado: /accesso/ lo muestra antes de pedir la contraseña, para que quien abrió el link
// sepa de qué cuenta es (un link reenviado, o de otra cuenta suya) sin mostrar la dirección entera en la pantalla.
// «evelyn.rossi@gmail.com» → «ev•••@g•••.com».

const DOTS = "•••";

/** El email enmascarado. Algo que no tiene forma de email se tapa entero. */
export function maskEmail(email: string): string {
  const at = email.lastIndexOf("@");
  if (at <= 0 || at === email.length - 1) return DOTS;
  const local = [...email.slice(0, at)];
  const domain = email.slice(at + 1);
  const dot = domain.lastIndexOf(".");
  const name = [...(dot > 0 ? domain.slice(0, dot) : domain)];
  const tld = dot > 0 ? domain.slice(dot) : "";
  const keep = local.length > 3 ? 2 : 1;
  return `${local.slice(0, keep).join("")}${DOTS}@${name[0] ?? ""}${DOTS}${tld}`;
}
