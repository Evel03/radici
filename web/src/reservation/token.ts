// El token del link de la clienta: va en el fragmento (#t=…), que el navegador no manda a ningún servidor ni en
// el Referer (docs/contracts/client-link.md §2). La página lo lee de acá y lo manda en el cuerpo de un POST a la
// función client-link; nunca en una URL, en la consola ni en analytics (no hay).

/** 43 caracteres base64url (32 bytes), sin otro carácter base64url pegado detrás. */
const TOKEN_AT_START = /^[A-Za-z0-9_-]{43}(?![A-Za-z0-9_-])/;

/**
 * El token de location.hash ("#t=…"), o null si no está o no tiene la forma de un token. Tolera lo que algunos
 * programas pegan al final de un link al copiarlo (un punto, un paréntesis): se queda con los 43 caracteres.
 */
export function readToken(hash: string): string | null {
  const value = new URLSearchParams(hash.replace(/^#/, "")).get("t");
  if (value === null) return null;
  return TOKEN_AT_START.exec(value)?.[0] ?? null;
}

/** El fragmento con el token: "#t=<token>". */
export function tokenFragment(token: string): string {
  return `#t=${token}`;
}

/**
 * Qué hacer cuando cambia el fragmento con la página abierta:
 * - "reload": llegó otro token (otro link pegado en la misma pestaña): se carga de nuevo.
 * - "restore": el fragmento ya no tiene token (por ejemplo, el link «Vai al contenuto», que lleva a #main): se
 *   vuelve a poner #t=<token> en la URL sin navegar (history.replaceState), así recargar o guardar la página
 *   sigue andando.
 * - "ignore": el mismo token (o la página abrió sin token y sigue sin uno).
 */
export function hashChangeAction(current: string | null, newHash: string): "reload" | "restore" | "ignore" {
  const next = readToken(newHash);
  if (next !== null && next !== current) return "reload";
  if (next === null && current !== null) return "restore";
  return "ignore";
}
