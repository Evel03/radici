// El link de los emails de Auth (los arma PR16): /accesso/?lang=<idioma>#token_hash=<hash>&type=email|recovery.
// - type=email: confirmar el alta (la segunda mitad del alta en dos pasos, docs/contracts/auth.md §11).
// - type=recovery: «Password dimenticata?».
// El fragmento no llega a ningún servidor ni va en el Referer. La página lo lee al abrir, lo saca de la URL enseguida
// (history.replaceState: recargar o compartir la pestaña ya no lo lleva) y lo guarda solo en memoria hasta el toque en
// «Conferma». Nunca va a la consola, a una URL, a un almacenamiento ni a otro servidor que Supabase Auth.

export type LinkType = "email" | "recovery";

export interface AccessLink {
  readonly tokenHash: string;
  readonly type: LinkType;
}

export type LinkRead =
  /** Un link completo: espera el toque en «Conferma». */
  | { readonly kind: "link"; readonly link: AccessLink }
  /** Algo del link llegó, pero no sirve (cortado, otro tipo): si se sabe el tipo, se ofrece pedir otro. */
  | { readonly kind: "broken"; readonly type: LinkType | null }
  /** La página se abrió sin link. */
  | { readonly kind: "none" };

/**
 * El token_hash de GoTrue: 56 hexadecimales (SHA-224), con «pkce_» delante si el pedido usó PKCE. Se acepta un rango
 * más amplio de letras, dígitos, «_» y «-»: la forma exacta la valida Auth, y acá solo se descarta lo que no puede
 * ser un token (espacios, otros símbolos, un link cortado).
 */
const TOKEN_HASH = /^[A-Za-z0-9_-]{20,200}$/;

/** Los parámetros del link en el fragmento (también los de error que GoTrue agrega a una redirección). */
const LINK_KEYS = ["token_hash", "type", "error", "error_code", "error_description"] as const;

function linkType(value: string | null): LinkType | null {
  return value === "email" || value === "recovery" ? value : null;
}

/** Lo que trae location.hash. */
export function readAccessLink(hash: string): LinkRead {
  const params = new URLSearchParams(hash.replace(/^#/, ""));
  if (!LINK_KEYS.some((key) => params.has(key))) return { kind: "none" };
  const tokenHash = params.get("token_hash");
  const type = linkType(params.get("type"));
  if (tokenHash !== null && TOKEN_HASH.test(tokenHash) && type !== null && !params.has("error_code")) {
    return { kind: "link", link: { tokenHash, type } };
  }
  return { kind: "broken", type };
}

/** ¿Hay que sacar el fragmento de la URL? Sí si trae algo del link (no, por ejemplo, el #main de «Vai al contenuto»). */
export function hasLinkParams(hash: string): boolean {
  const params = new URLSearchParams(hash.replace(/^#/, ""));
  return LINK_KEYS.some((key) => params.has(key));
}

/** La dirección sin el fragmento, para history.replaceState: conserva la ruta y la query (?lang=). */
export function addressWithoutFragment(location: { readonly pathname: string; readonly search: string }): string {
  return `${location.pathname}${location.search}`;
}
