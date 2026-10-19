// IP del visitante para el límite de pedidos por IP. La IP nunca se guarda ni se loguea:
// se guarda un HMAC-SHA-256 con IP_HASH_SALT como clave.
// Solo sintaxis borrable: corre en Node (tests) y Deno (Edge Functions).

const IPV4 = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/;
const IPV4_WITH_PORT = /^(\d{1,3}(?:\.\d{1,3}){3}):\d{1,5}$/;
const HEXTET = /^[0-9a-f]{1,4}$/;

function isIpv4(value: string): boolean {
  const match = IPV4.exec(value);
  return match !== null && match.slice(1).every((part) => Number(part) <= 255);
}

/** Expande una IPv6 a sus 8 grupos (sin ceros a la izquierda), o null si no es válida. */
function ipv6Groups(value: string): string[] | null {
  if (value.includes(".")) return null; // las IPv4 mapeadas se tratan aparte
  const halves = value.split("::");
  if (halves.length > 2) return null;
  const left = halves[0] ? halves[0].split(":") : [];
  const right = halves.length === 2 && halves[1] ? halves[1].split(":") : [];
  const missing = 8 - left.length - right.length;
  if (halves.length === 2 ? missing < 1 : missing !== 0) return null;
  const groups = [...left, ...Array<string>(halves.length === 2 ? missing : 0).fill("0"), ...right];
  if (!groups.every((group) => HEXTET.test(group))) return null;
  return groups.map((group) => group.replace(/^0+(?=.)/, ""));
}

function normalizeIp(raw: string | null | undefined): string | null {
  if (!raw) return null;
  let value = raw.trim().toLowerCase();
  const withPort = IPV4_WITH_PORT.exec(value);
  if (withPort?.[1]) value = withPort[1];
  if (isIpv4(value)) return value;
  if (value.startsWith("::ffff:") && isIpv4(value.slice(7))) return value;
  return ipv6Groups(value) ? value : null;
}

/**
 * IP del visitante. Primero cf-connecting-ip (Cloudflare, delante de Supabase, la reemplaza por la
 * real). Si falta, la última de x-forwarded-for: es la que agregó el último proxy; las primeras las
 * puede escribir el cliente.
 */
export function clientIp(headers: Headers): string | null {
  const cloudflare = normalizeIp(headers.get("cf-connecting-ip"));
  if (cloudflare) return cloudflare;
  const forwarded = headers.get("x-forwarded-for");
  if (!forwarded) return null;
  const hops = forwarded.split(",");
  return normalizeIp(hops[hops.length - 1]);
}

/**
 * Clave del límite: una IPv4 tal cual; de una IPv6, su prefijo /64 (un mismo cliente suele tener
 * todo el /64 y puede rotar dentro de él). Una IPv4 mapeada en IPv6 cuenta como IPv4.
 */
export function rateLimitSubject(ip: string): string {
  const value = ip.trim().toLowerCase();
  if (value.startsWith("::ffff:") && isIpv4(value.slice(7))) return value.slice(7);
  const groups = ipv6Groups(value);
  if (!groups) return value;
  return `${groups.slice(0, 4).join(":")}::/64`;
}

/** HMAC-SHA-256 en hexadecimal (64 caracteres) de la clave del límite, con la sal como clave. */
export async function hashSubject(subject: string, salt: string): Promise<string> {
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey("raw", encoder.encode(salt), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const signature = await crypto.subtle.sign("HMAC", key, encoder.encode(subject));
  return Array.from(new Uint8Array(signature), (byte) => byte.toString(16).padStart(2, "0")).join("");
}
