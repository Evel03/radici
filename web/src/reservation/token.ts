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
